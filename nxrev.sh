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

NX_INBOUND_MISSING=0
NX_INBOUND_BROKEN=0

NX_HTTP2_LISTEN=""
NX_HTTP2_DIRECTIVE=""

usage() {
    cat <<'USAGE'
nx-revpro — VLESS+REALITY за nginx SNI-роутером.

  nxrev.sh install --panel <домен> --decoy <домен> [--email <адрес>] [опции]
  nxrev.sh status
  nxrev.sh links
  nxrev.sh regen-decoy

Опции install:
  --panel   <домен>   домен панели и подписки (SNI → nginx :7443)
  --decoy   <домен>   домен-прикрытие, он же serverName для REALITY
  --email   <адрес>   контакт для Let's Encrypt
  --bind-ip <ip>      публичный IP для nginx (по умолчанию — из таблицы маршрутов)
  --share-address <хост>  адрес в share-ссылке (по умолчанию decoy-домен)
  --remark  <строка>  имя инбаунда (по умолчанию nx-reality)
  --staging           тестовый CA Let's Encrypt: для отладки, без лимита 5/неделю
  --no-staging        вернуться к боевому CA после отладки
  --regen-decoy       пересобрать сайт-прикрытие заново
  --force             не падать, если DNS ещё не разъехался
  -h, --help          эта справка

Инбаунд создаётся руками в панели: API 3x-ui меняется от версии к версии,
и автосоздание ломалось бы на каждом обновлении. Скрипт его находит, сверяет
с конфигурацией nginx и показывает ссылки.

Повторный запуск install безопасен: конфиги и сертификаты обновляются.
USAGE
}

load_conf() {
    [[ -r $NX_CONF ]] || return 0
    # shellcheck disable=SC1090
    . "$NX_CONF"
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
    local need_value="--panel --decoy --email --bind-ip --share-address --remark "
    while (( $# )); do
        [[ $need_value == *"$1 "* && $# -lt 2 ]] && die "у $1 нет значения"
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
            -h|--help)        usage; exit 0 ;;
            *) die "неизвестный аргумент: $1 (--help)" ;;
        esac
    done
}

resolve_addresses() {
    [[ -n $BIND_IP ]] || BIND_IP=$(detect_bind_ip)
    [[ -n $BIND_IP ]] || die "не определил IP для bind — задайте --bind-ip"

    if ! PUBLIC_IP=$(detect_public_ip); then
        warn "не смог узнать внешний IP, считаю его равным $BIND_IP"
        PUBLIC_IP=$BIND_IP
    fi
    if [[ $PUBLIC_IP != "$BIND_IP" ]]; then
        info "внешний IP $PUBLIC_IP, локальный $BIND_IP — похоже на NAT, слушаю $BIND_IP"
    fi
    ok "bind ${BIND_IP}:443, снаружи ${PUBLIC_IP}:${PUBLIC_PORT}"
}

# --- install ---------------------------------------------------------------

cmd_install() {
    [[ -n $PANEL_DOMAIN ]] || die "не задан --panel"
    [[ -n $DECOY_DOMAIN ]] || die "не задан --decoy"
    [[ $PANEL_DOMAIN != "$DECOY_DOMAIN" ]] || die "--panel и --decoy должны различаться"
    [[ -n $SHARE_ADDRESS ]] || SHARE_ADDRESS=$DECOY_DOMAIN
    state_init

    step "Проверка окружения"
    preflight_root
    preflight_os
    preflight_packages
    preflight_nginx_modules
    preflight_nginx_http2_style
    preflight_xui

    step "Сеть и DNS"
    resolve_addresses
    check_dns "$PANEL_DOMAIN" "$PUBLIC_IP"
    check_dns "$DECOY_DOMAIN" "$PUBLIC_IP"
    preflight_ports "$BIND_IP"

    step "Настройки панели (как есть)"
    panel_report_settings

    step "Привожу панель к работе за nginx"
    panel_apply_settings "$PANEL_DOMAIN"

    save_conf

    step "Сайт-прикрытие"
    decoy_generate "$REGEN_DECOY"

    step "nginx: временный профиль только с :80 (для ACME)"
    nginx_phase_acme

    step "Сертификаты Let's Encrypt"
    [[ $STAGING == 1 ]] && warn "режим --staging: сертификаты не доверенные, для отладки"
    certs_install_hook
    nginx_assert_loaded
    certs_selftest "$PANEL_DOMAIN" || die "ACME-челлендж не доедет — сертификат не выпустить"
    certs_selftest "$DECOY_DOMAIN" || die "ACME-челлендж не доедет — сертификат не выпустить"
    certs_issue "$PANEL_DOMAIN"
    certs_issue "$DECOY_DOMAIN"
    certs_check_timer

    step "nginx: полный SNI-роутер"
    nginx_phase_full

    step "Инбаунд VLESS+REALITY"
    report_inbound

    step "Проверка"
    save_conf
    do_verify || warn "часть проверок не прошла — смотрите вывод выше"

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
            warn "инбаунда '$INBOUND_REMARK' нет, но порт $XRAY_PORT занят инбаундом '$(jq -r .remark <<<"$clash")'"
            inb=$clash
        else
            NX_INBOUND_MISSING=1
            warn "инбаунд не найден — создайте его в панели, параметры ниже"
            return 0
        fi
    fi

    if inbound_check "$inb"; then
        ok "инбаунд '$(jq -r .remark <<<"$inb")' сходится с конфигурацией nginx"
    else
        NX_INBOUND_BROKEN=1
        err "инбаунд не сходится с конфигурацией nginx — поправьте в панели"
    fi

    state_set INBOUND_ID "$(jq -r '.id' <<<"$inb")"
    state_set REALITY_PUBLIC_KEY \
        "$(jq -r '.streamSettings // "{}" | fromjson? | .realitySettings.settings.publicKey // ""' <<<"$inb" 2>/dev/null || true)"
}

# Что показать человеку, если инбаунда ещё нет либо он разъехался.
print_inbound_instructions() {
    printf '\n%s--- Инбаунд нужно завести в панели ---%s\n' "$C_YEL" "$C_OFF"
    printf 'Панель: https://%s%s\n\n' "$PANEL_DOMAIN" "$PANEL_BASE_PATH"
    inbound_expected_hint
    cat <<'TAIL'

  Публичный ключ REALITY панель сгенерирует сама кнопкой "Get New Cert".
  Клиентов добавляйте там же; flow у каждого — xtls-rprx-vision.

Потом:  nxrev links   — покажет vless://-ссылки и QR
TAIL
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
            ok "слушает $a:$p ($name)"
        elif [[ $name == xray-reality && ${NX_INBOUND_MISSING:-0} == 1 ]]; then
            info "127.0.0.1:$p свободен — инбаунда ещё нет, это ожидаемо"
        else
            err "никто не слушает $a:$p ($name)"; rc=1
        fi
    done

    code=$(_http_code "$PANEL_DOMAIN" "$PANEL_BASE_PATH")
    if [[ $code == 200 ]]; then ok "панель через SNI-роутер отвечает 200"
    else err "панель по https://${PANEL_DOMAIN}${PANEL_BASE_PATH} вернула $code"; rc=1; fi

    # Сначала сам decoy-сервер, напрямую: если он не отвечает, REALITY тут ни при чём.
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
           --resolve "${DECOY_DOMAIN}:${DECOY_HTTPS_PORT}:127.0.0.1" \
           "https://${DECOY_DOMAIN}:${DECOY_HTTPS_PORT}/" 2>/dev/null) || code=000
    if [[ $code == 200 ]]; then
        ok "прикрытие на 127.0.0.1:${DECOY_HTTPS_PORT} отвечает напрямую"
    else
        err "прикрытие на 127.0.0.1:${DECOY_HTTPS_PORT} вернуло $code — это nginx, не REALITY"
        rc=1
    fi

    if [[ ${NX_INBOUND_MISSING:-0} == 1 ]]; then
        info "проверку REALITY пропускаю: инбаунда ещё нет"
    else
        code=$(_http_code "$DECOY_DOMAIN" "/")
        if [[ $code == 200 ]]; then ok "прикрытие через REALITY-fallback отвечает 200"
        else
            err "https://${DECOY_DOMAIN}/ вернул $code — REALITY не передал соединение на :${DECOY_HTTPS_PORT}"
            err "  Частая причина: у инбаунда выключен Proxy Protocol, а stream-роутер его шлёт."
            err "  Путь целиком:  openssl s_client -connect ${BIND_IP}:443 -servername $DECOY_DOMAIN </dev/null"
            rc=1
        fi
    fi

    if [[ ${NX_INBOUND_MISSING:-0} == 1 ]]; then
        info "проверку сертификата на decoy-SNI пропускаю: соединение идёт через REALITY"
        return $rc
    fi

    issuer=$(echo | openssl s_client -connect "${BIND_IP}:${PUBLIC_PORT}" \
                -servername "$DECOY_DOMAIN" 2>/dev/null \
             | openssl x509 -noout -issuer 2>/dev/null || true)
    if grep -q "Let's Encrypt\|STAGING" <<<"$issuer"; then
        ok "на decoy-SNI отдаётся сертификат: ${issuer#issuer=}"
    else
        err "на decoy-SNI пришёл не тот сертификат: ${issuer:-<пусто>}"; rc=1
    fi

    return $rc
}

print_summary() {
    local inb
    inb=$(inbound_find "$INBOUND_REMARK")

    printf '\n%s================ ГОТОВО ================%s\n' "$C_GRN" "$C_OFF"
    printf '  Панель      https://%s%s\n' "$PANEL_DOMAIN" "$PANEL_BASE_PATH"
    printf '  Подписка    https://%s%s<subId>\n' "$PANEL_DOMAIN" "$PANEL_SUB_PATH"
    printf '  Прикрытие   https://%s/   (%s)\n' "$DECOY_DOMAIN" "$(state_get DECOY_BRAND)"
    printf '  Сертификаты\n'
    certs_report "$PANEL_DOMAIN" "$DECOY_DOMAIN"
    [[ $STAGING == 1 ]] && printf '  %sСертификаты тестовые (--staging). Перезапустите с --no-staging для боевых.%s\n' "$C_YEL" "$C_OFF"
    printf '  Конфиг      %s\n  Состояние   %s\n' "$NX_CONF" "$NX_STATE"

    if [[ ${NX_INBOUND_MISSING:-0} == 1 || ${NX_INBOUND_BROKEN:-0} == 1 || -z $inb ]]; then
        print_inbound_instructions
        return 0
    fi

    printf '\n  Ссылки:\n'
    inbound_print_links "$inb"
    printf '\n  Новых клиентов добавляйте в панели, затем:  nxrev links\n'
}

# --- прочие команды --------------------------------------------------------

_need_installed() {
    [[ -n $PANEL_DOMAIN && -n $DECOY_DOMAIN ]] \
        || die "нет $NX_CONF — сначала запустите: $NX_SELF install --panel ... --decoy ..."
    preflight_root
    preflight_xui
    [[ -n $BIND_IP ]] || BIND_IP=$(detect_bind_ip)
    panel_read_settings
}

cmd_status() {
    _need_installed
    step "Инбаунд"
    report_inbound
    [[ ${NX_INBOUND_MISSING:-0} == 1 ]] && print_inbound_instructions
    step "Настройки панели"
    panel_report_settings
    step "Сертификаты"
    certs_report "$PANEL_DOMAIN" "$DECOY_DOMAIN"
    certs_check_timer
    step "Сквозная проверка"
    do_verify
}

cmd_links() {
    _need_installed
    local inb
    inb=$(inbound_find "$INBOUND_REMARK")
    [[ -n $inb ]] || die "инбаунд '$INBOUND_REMARK' не найден"
    inbound_print_links "$inb"
}


cmd_regen_decoy() {
    _need_installed
    decoy_generate 1
    nginx_reload
}

# --- точка входа -----------------------------------------------------------

main() {
    local cmd=${1:-install}
    [[ $# -gt 0 ]] && shift || true
    load_conf

    case $cmd in
        install)      parse_args "$@"; cmd_install ;;
        status)       parse_args "$@"; cmd_status ;;
        links)        parse_args "$@"; cmd_links ;;
        regen-decoy)  parse_args "$@"; cmd_regen_decoy ;;
        -h|--help|help) usage ;;
        *) usage; die "неизвестная команда: $cmd" ;;
    esac
}

main "$@"
