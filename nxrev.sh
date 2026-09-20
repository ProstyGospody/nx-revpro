#!/usr/bin/env bash
#
# nx-revpro — VLESS+REALITY за nginx SNI-роутером, поверх уже установленной 3x-ui.
#
#   публичный IP:443 ──ssl_preread──┬── panel.example.com  → 127.0.0.1:7443 (nginx, панель+подписка)
#                                   ├── decoy.example.com  → 127.0.0.1:443  (Xray REALITY)
#                                   └── всё остальное      → 127.0.0.1:443  (Xray REALITY)
#                                                                  └─ fallback → 127.0.0.1:9443 (сайт-прикрытие)
#
# Панель ставится отдельно (см. README), скрипт только приводит её в порядок,
# выпускает сертификаты, поднимает роутер и создаёт инбаунд.
set -euo pipefail

NX_SELF=$(readlink -f "${BASH_SOURCE[0]}")
NX_HOME=$(dirname "$NX_SELF")

# shellcheck source=lib/common.sh
. "$NX_HOME/lib/common.sh"
. "$NX_HOME/lib/preflight.sh"
. "$NX_HOME/lib/panel.sh"
. "$NX_HOME/lib/certs.sh"
. "$NX_HOME/lib/nginx.sh"
. "$NX_HOME/lib/decoy.sh"
. "$NX_HOME/lib/inbound.sh"
. "$NX_HOME/lib/rollback.sh"

# --- значения по умолчанию -------------------------------------------------
PANEL_DOMAIN=""
DECOY_DOMAIN=""
LE_EMAIL=""
BIND_IP=""
PUBLIC_IP=""
SHARE_ADDRESS=""
STAGING=0
FORCE=0
REGEN_DECOY=0

PUBLIC_PORT=443          # порт, на котором нас видит клиент
XRAY_PORT=443            # порт инбаунда = порт в share-ссылке, менять нельзя
PANEL_HTTPS_PORT=7443
DECOY_HTTPS_PORT=9443
INBOUND_REMARK="nx-reality"

NX_ASSUME_YES=0
NX_LANG_CONF=""
NX_INBOUND_MISSING=0
NX_INBOUND_BROKEN=0

NX_HTTP2_LISTEN=""
NX_HTTP2_DIRECTIVE=""

usage() { printf '%s\n' "${M[usage]}"; }

load_conf() {
    [[ -r $NX_CONF ]] || return 0
    # shellcheck disable=SC1090
    . "$NX_CONF"
    NX_LANG_CONF=${NX_LANG_CONF:-}
}

save_conf() {
    state_init
    (umask 077; cat > "$NX_CONF" <<CONF
# nx-revpro — сохранено $(date -Is). Правится руками, читается при каждом запуске.
PANEL_DOMAIN="$PANEL_DOMAIN"
DECOY_DOMAIN="$DECOY_DOMAIN"
LE_EMAIL="$LE_EMAIL"
BIND_IP="$BIND_IP"
SHARE_ADDRESS="$SHARE_ADDRESS"
INBOUND_REMARK="$INBOUND_REMARK"
STAGING=$STAGING
NX_LANG_CONF="$NX_LANG"

# Порты фиксированы архитектурой; XRAY_PORT обязан совпадать с PUBLIC_PORT,
# иначе панель положит в share-ссылку не тот порт.
PUBLIC_PORT=$PUBLIC_PORT
XRAY_PORT=$XRAY_PORT
PANEL_HTTPS_PORT=$PANEL_HTTPS_PORT
DECOY_HTTPS_PORT=$DECOY_HTTPS_PORT

CONF
    )
    chmod 600 "$NX_CONF"
}

parse_args() {
    local need_value="--panel --decoy --email --bind-ip --share-address --remark --lang --apt-wait "
    while (( $# )); do
        [[ $need_value == *"$1 "* && $# -lt 2 ]] && diem arg_noval "$1"
        case $1 in
            --panel)          PANEL_DOMAIN=$2; shift 2 ;;
            --decoy)          DECOY_DOMAIN=$2; shift 2 ;;
            --email)          LE_EMAIL=$2; shift 2 ;;
            --bind-ip)        BIND_IP=$2; shift 2 ;;
            --share-address)  SHARE_ADDRESS=$2; shift 2 ;;
            --remark)         INBOUND_REMARK=$2; shift 2 ;;
            --staging)        STAGING=1; shift ;;
            --no-staging)     STAGING=0; shift ;;
            --regen-decoy)    REGEN_DECOY=1; shift ;;
            --force)          FORCE=1; shift ;;
            --lang)           i18n_load "$2"; shift 2 ;;
            --apt-wait)       NX_APT_WAIT=$2; shift 2 ;;
            -y|--yes)         NX_ASSUME_YES=1; shift ;;
            -h|--help)        usage; exit 0 ;;
            *) diem arg_unknown "$1" ;;
        esac
    done
}

resolve_addresses() {
    [[ -n $BIND_IP ]] || BIND_IP=$(detect_bind_ip)
    [[ -n $BIND_IP ]] || diem bind_unknown

    if ! PUBLIC_IP=$(detect_public_ip); then
        warnm pub_unknown "$BIND_IP"
        PUBLIC_IP=$BIND_IP
    fi
    if [[ $PUBLIC_IP != "$BIND_IP" ]]; then
        infom nat_detected "$PUBLIC_IP" "$BIND_IP"
    fi
    okm addr_ok "$BIND_IP" "$PUBLIC_IP" "$PUBLIC_PORT"
}

# --- install ---------------------------------------------------------------

cmd_install() {
    NX_STEP_TOTAL=10
    banner
    trap rollback_on_failure EXIT
    [[ -n $PANEL_DOMAIN ]] || diem need_panel
    [[ -n $DECOY_DOMAIN ]] || diem need_decoy
    [[ $PANEL_DOMAIN != "$DECOY_DOMAIN" ]] || diem same_domains
    [[ -n $SHARE_ADDRESS ]] || SHARE_ADDRESS=$DECOY_DOMAIN
    state_init

    stepm step_env
    preflight_root
    preflight_os
    preflight_packages
    preflight_nginx_modules
    preflight_nginx_http2_style
    preflight_xui

    stepm step_net
    resolve_addresses
    check_dns "$PANEL_DOMAIN" "$PUBLIC_IP"
    check_dns "$DECOY_DOMAIN" "$PUBLIC_IP"
    preflight_ports "$BIND_IP"

    stepm step_panel_read
    panel_report_settings

    stepm step_panel_apply
    rollback_arm
    panel_apply_settings "$PANEL_DOMAIN"

    save_conf

    stepm step_decoy
    decoy_generate "$REGEN_DECOY"

    stepm step_acme
    nginx_phase_acme

    stepm step_certs
    [[ $STAGING == 1 ]] && warnm staging_warn
    certs_install_hook
    nginx_assert_loaded
    certs_selftest "$PANEL_DOMAIN" || diem acme_blocked
    certs_selftest "$DECOY_DOMAIN" || diem acme_blocked
    certs_issue "$PANEL_DOMAIN"
    certs_issue "$DECOY_DOMAIN"
    certs_check_timer

    stepm step_full
    nginx_phase_full

    stepm step_inbound
    report_inbound

    stepm step_verify
    save_conf
    do_verify || warnm v_partial

    rollback_disarm
    apt_restore_auto_updates
    print_summary
}

# Инбаунд заводится руками в панели. Скрипт его только находит и сверяет с
# тем, что настроил nginx: создавать через API — значит ломаться на каждом
# обновлении панели, как это и случилось с типом поля tgId.
report_inbound() {
    local inb clash
    inb=$(inbound_find "$INBOUND_REMARK")

    if [[ -z $inb ]]; then
        clash=$(inbound_find_by_port "$XRAY_PORT")
        if [[ -n $clash ]]; then
            warnm inb_port_taken "$INBOUND_REMARK" "$XRAY_PORT" "$(jq -r .remark <<<"$clash")"
            inb=$clash
        else
            NX_INBOUND_MISSING=1
            warnm inb_missing
            return 0
        fi
    fi

    if inbound_check "$inb"; then
        okm inb_ok "$(jq -r .remark <<<"$inb")"
    else
        NX_INBOUND_BROKEN=1
        errm inb_broken
    fi

    state_set INBOUND_ID "$(jq -r '.id' <<<"$inb")"
    state_set REALITY_PUBLIC_KEY \
        "$(jq -r '.streamSettings // "{}" | fromjson? | .realitySettings.settings.publicKey // ""' <<<"$inb" 2>/dev/null || true)"
}

# Что показать человеку, если инбаунда ещё нет либо он разъехался.
# Что показать человеку, если инбаунда ещё нет либо он разъехался.
print_inbound_instructions() {
    printf '\n  %s%s%s\n' "$C_YEL$C_B" "${M[inb_title]}" "$C_OFF"
    printf '  %s\n\n' "$(_m inb_panel_at "$PANEL_DOMAIN" "$PANEL_BASE_PATH")"
    inbound_expected_hint
    printf '\n  %s%s%s\n' "$C_DIM" "${M[inb_notes]}" "$C_OFF"
    printf '    %s%s%s\n'  "$C_DIM" "${M[inb_note_pp]}" "$C_OFF"
    printf '    %s%s%s\n'  "$C_DIM" "${M[inb_note_share]}" "$C_OFF"
    printf '    %s%s%s\n'  "$C_DIM" "${M[inb_note_keys]}" "$C_OFF"
}

# --- проверки --------------------------------------------------------------

_listening() { listening "$1" "$2"; }

_http_code() {
    local host=$1 path=$2 code
    # без "|| echo 000": curl уже печатает 000 при ошибке, приписка склеивала "000000"
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
           --resolve "${host}:${PUBLIC_PORT}:${BIND_IP}" \
           "https://${host}:${PUBLIC_PORT}${path}" 2>/dev/null) || code=000
    printf '%s' "${code:-000}"
}

do_verify() {
    local rc=0 code issuer spec a p name

    for spec in "${BIND_IP} 443 nginx-stream" "0.0.0.0 80 nginx-acme" \
                "127.0.0.1 ${PANEL_HTTPS_PORT} nginx-panel" \
                "127.0.0.1 ${DECOY_HTTPS_PORT} nginx-decoy" \
                "127.0.0.1 ${XRAY_PORT} xray-reality"; do
        read -r a p name <<<"$spec"
        if _listening "$a" "$p"; then
            okm v_listen_ok "$a" "$p" "$name"
        elif [[ $name == xray-reality && ${NX_INBOUND_MISSING:-0} == 1 ]]; then
            infom v_listen_skip "$p"
        else
            errm v_listen_no "$a" "$p" "$name"; rc=1
        fi
    done

    code=$(_http_code "$PANEL_DOMAIN" "$PANEL_BASE_PATH")
    if [[ $code == 200 ]]; then okm v_panel_ok
    else errm v_panel_no "$PANEL_DOMAIN" "$PANEL_BASE_PATH" "$code"; rc=1; fi

    # Сначала сам decoy-сервер, напрямую: если он не отвечает, REALITY тут ни при чём.
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
           --resolve "${DECOY_DOMAIN}:${DECOY_HTTPS_PORT}:127.0.0.1" \
           "https://${DECOY_DOMAIN}:${DECOY_HTTPS_PORT}/" 2>/dev/null) || code=000
    if [[ $code == 200 ]]; then
        okm v_decoy_direct_ok "$DECOY_HTTPS_PORT"
    else
        errm v_decoy_direct_no "$DECOY_HTTPS_PORT" "$code"
        rc=1
    fi

    if [[ ${NX_INBOUND_MISSING:-0} == 1 ]]; then
        infom v_reality_skip
    else
        code=$(_http_code "$DECOY_DOMAIN" "/")
        if [[ $code == 200 ]]; then okm v_reality_ok
        else
            errm v_reality_no "$DECOY_DOMAIN" "$code" "$DECOY_HTTPS_PORT"
            errm v_reality_hint
            rc=1
        fi
    fi

    if [[ ${NX_INBOUND_MISSING:-0} == 1 ]]; then
        infom v_cert_skip
        return $rc
    fi

    issuer=$(echo | openssl s_client -connect "${BIND_IP}:${PUBLIC_PORT}" \
                -servername "$DECOY_DOMAIN" 2>/dev/null \
             | openssl x509 -noout -issuer 2>/dev/null || true)
    if grep -q "Let's Encrypt\|STAGING" <<<"$issuer"; then
        okm v_cert_ok "${issuer#issuer=}"
    else
        errm v_cert_no "${issuer:-${M[val_empty]}}"; rc=1
    fi

    return $rc
}

print_summary() {
    local inb
    inb=$(inbound_find "$INBOUND_REMARK")

    printf '\n  %s%s %s%s\n' "$C_GRN$C_B" "$S_OK" "${M[sum_title]}" "$C_OFF"
    printf '  %s%s%s\n' "$C_DIM" "──────────────────────────────────────────────" "$C_OFF"
    kv "${M[sum_panel]}"  "https://${PANEL_DOMAIN}${PANEL_BASE_PATH}"
    kv "${M[sum_sub]}"    "https://${PANEL_DOMAIN}${PANEL_SUB_PATH}<subId>"
    kv "${M[sum_decoy]}"  "https://${DECOY_DOMAIN}/  ($(state_get DECOY_BRAND))"
    kv "${M[sum_conf]}"   "$NX_CONF"
    kv "${M[sum_state]}"  "$NX_STATE"
    printf '\n'
    certs_report "$PANEL_DOMAIN" "$DECOY_DOMAIN"
    [[ $STAGING == 1 ]] && warnm sum_staging

    if [[ ${NX_INBOUND_MISSING:-0} == 1 || ${NX_INBOUND_BROKEN:-0} == 1 || -z $inb ]]; then
        print_inbound_instructions
        return 0
    fi

    printf '\n  %s%s%s\n' "$C_B" "${M[sum_links]}" "$C_OFF"
    inbound_print_links "$inb"
    printf '\n  %s%s%s\n' "$C_DIM" "${M[sum_addmore]}" "$C_OFF"
}

# --- прочие команды --------------------------------------------------------

_need_installed() {
    [[ -n $PANEL_DOMAIN && -n $DECOY_DOMAIN ]] \
        || diem not_installed "$NX_CONF"
    preflight_root
    preflight_xui
    [[ -n $BIND_IP ]] || BIND_IP=$(detect_bind_ip)
    panel_read_settings
}

cmd_status() {
    _need_installed
    stepm step_inbound
    report_inbound
    [[ ${NX_INBOUND_MISSING:-0} == 1 ]] && print_inbound_instructions
    stepm step_panel_read
    panel_report_settings
    stepm step_certs
    certs_report "$PANEL_DOMAIN" "$DECOY_DOMAIN"
    certs_check_timer
    stepm step_verify
    do_verify
}

cmd_links() {
    _need_installed
    local inb
    inb=$(inbound_find "$INBOUND_REMARK")
    [[ -n $inb ]] || diem inb_notfound "$INBOUND_REMARK"
    inbound_print_links "$inb"
}


cmd_regen_decoy() {
    _need_installed
    decoy_generate 1
    nginx_reload
}

# --- точка входа -----------------------------------------------------------

cmd_uninstall() {
    preflight_root
    [[ -n $PANEL_DOMAIN ]] || PANEL_DOMAIN="<домен>"
    uninstall_all "${NX_ASSUME_YES:-0}"
}

main() {
    local cmd=${1:-install}
    [[ $# -gt 0 ]] && shift || true

    # Язык: переменная окружения, затем конфиг, затем --lang в parse_args.
    i18n_load "${NX_LANG:-ru}"
    load_conf
    [[ -n ${NX_LANG_CONF:-} ]] && i18n_load "$NX_LANG_CONF"

    case $cmd in
        install)      parse_args "$@"; cmd_install ;;
        status)       parse_args "$@"; cmd_status ;;
        links)        parse_args "$@"; cmd_links ;;
        regen-decoy)  parse_args "$@"; cmd_regen_decoy ;;
        uninstall)    parse_args "$@"; cmd_uninstall ;;
        -h|--help|help) banner; usage ;;
        *) banner; usage; diem cmd_unknown "$cmd" ;;
    esac
}

main "$@"
