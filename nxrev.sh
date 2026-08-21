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
FIRST_CLIENT="owner"

NX_HTTP2_LISTEN=""
NX_HTTP2_DIRECTIVE=""

usage() {
    cat <<'USAGE'
nx-revpro — VLESS+REALITY за nginx SNI-роутером.

  nxrev.sh install --panel <домен> --decoy <домен> [--email <адрес>] [опции]
  nxrev.sh status
  nxrev.sh links
  nxrev.sh add-user <имя>
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

Повторный запуск install безопасен: конфиги и сертификаты обновляются,
существующий инбаунд не трогается.
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

# Доступ к API панели. Пусто — берётся токен/логин из $XUI_ENV.
PANEL_TOKEN="${PANEL_TOKEN:-}"
PANEL_USER="${PANEL_USER:-}"
PANEL_PASS="${PANEL_PASS:-}"
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

    step "Доступ к API панели"
    panel_auth

    step "Сайт-прикрытие"
    decoy_generate "$REGEN_DECOY"

    step "nginx: временный профиль только с :80 (для ACME)"
    nginx_phase_acme

    step "Сертификаты Let's Encrypt"
    [[ $STAGING == 1 ]] && warn "режим --staging: сертификаты не доверенные, для отладки"
    certs_install_hook
    certs_issue "$PANEL_DOMAIN"
    certs_issue "$DECOY_DOMAIN"
    certs_check_timer

    step "nginx: полный SNI-роутер"
    nginx_phase_full

    step "Инбаунд VLESS+REALITY"
    ensure_inbound

    step "Проверка"
    save_conf
    do_verify || warn "часть проверок не прошла — смотрите вывод выше"

    print_summary
}

ensure_inbound() {
    local inb
    inb=$(inbound_find "$INBOUND_REMARK")

    if [[ -z $inb ]]; then
        local clash
        clash=$(inbound_find_by_port "$XRAY_PORT")
        [[ -n $clash ]] && die "порт $XRAY_PORT уже занят инбаундом '$(jq -r .remark <<<"$clash")' — переименуйте его или задайте --remark"
        inbound_create "$FIRST_CLIENT" > /dev/null
        inb=$(inbound_find "$INBOUND_REMARK")
        [[ -n $inb ]] || die "инбаунд создан, но не нашёлся в списке"
        wait_listen 127.0.0.1 "$XRAY_PORT" 20 || warn "Xray ещё не слушает 127.0.0.1:$XRAY_PORT"
    else
        ok "инбаунд '$INBOUND_REMARK' уже есть — не трогаю, только сверяю"
        check_inbound "$inb"
    fi

    state_set INBOUND_ID "$(jq -r '.id' <<<"$inb")"
    state_set REALITY_PUBLIC_KEY \
        "$(jq -r '.streamSettings | fromjson | .realitySettings.settings.publicKey // ""' <<<"$inb")"
}

# Существующий инбаунд не правим (это перевыпустило бы ключи и сломало клиентов),
# но обязаны сказать, если он разошёлся с тем, что настроил nginx.
check_inbound() {
    local inb=$1 ss v
    ss=$(jq -r '.streamSettings' <<<"$inb")

    v=$(jq -r '.port' <<<"$inb")
    [[ $v == "$XRAY_PORT" ]] || warn "инбаунд на порту $v — именно его панель положит в share-ссылку, а снаружи слушается $PUBLIC_PORT"
    v=$(jq -r '.listen // ""' <<<"$inb")
    [[ $v == "127.0.0.1" ]] || warn "инбаунд слушает '${v:-все интерфейсы}', ожидалось 127.0.0.1"
    v=$(jq -r '.tcpSettings.acceptProxyProtocol // false' <<<"$ss")
    [[ $v == true ]] || err "у инбаунда acceptProxyProtocol=false, а stream-роутер шлёт PROXY — соединения не поднимутся"
    v=$(jq -r '.realitySettings.dest // ""' <<<"$ss")
    [[ $v == "127.0.0.1:${DECOY_HTTPS_PORT}" ]] || warn "realitySettings.dest = '$v', ожидалось 127.0.0.1:${DECOY_HTTPS_PORT}"
    v=$(jq -r '.realitySettings.serverNames[0] // ""' <<<"$ss")
    [[ $v == "$DECOY_DOMAIN" ]] || warn "serverNames[0] = '$v', а сертификат выписан на $DECOY_DOMAIN"
}

# Панель перезапускает Xray асинхронно — даём инбаунду встать, иначе проверка
# постучится в 127.0.0.1:443 раньше, чем там кто-то появится.
wait_listen() {
    local addr=$1 port=$2 tries=${3:-20} i
    for (( i = 0; i < tries; i++ )); do
        _listening "$addr" "$port" && return 0
        sleep 1
    done
    return 1
}

# --- проверки --------------------------------------------------------------

# Фильтры ss по-разному разбираются в разных версиях — проще отфильтровать сами.
_listening() { ss -lntH 2>/dev/null | awk -v a="$1:$2" '$4 == a { f = 1 } END { exit !f }'; }

_http_code() {
    local host=$1 path=$2
    curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        --resolve "${host}:${PUBLIC_PORT}:${BIND_IP}" "https://${host}:${PUBLIC_PORT}${path}" 2>/dev/null || echo 000
}

do_verify() {
    local rc=0 code issuer spec a p name

    for spec in "${BIND_IP} 443 nginx-stream" "${BIND_IP} 80 nginx-acme" \
                "127.0.0.1 ${PANEL_HTTPS_PORT} nginx-panel" \
                "127.0.0.1 ${DECOY_HTTPS_PORT} nginx-decoy" \
                "127.0.0.1 ${XRAY_PORT} xray-reality"; do
        read -r a p name <<<"$spec"
        if _listening "$a" "$p"; then ok "слушает $a:$p ($name)"
        else err "никто не слушает $a:$p ($name)"; rc=1; fi
    done

    code=$(_http_code "$PANEL_DOMAIN" "$PANEL_BASE_PATH")
    if [[ $code == 200 ]]; then ok "панель через SNI-роутер отвечает 200"
    else err "панель по https://${PANEL_DOMAIN}${PANEL_BASE_PATH} вернула $code"; rc=1; fi

    code=$(_http_code "$DECOY_DOMAIN" "/")
    if [[ $code == 200 ]]; then ok "прикрытие через REALITY-fallback отвечает 200"
    else err "https://${DECOY_DOMAIN}/ вернул $code (REALITY не отдал соединение на :${DECOY_HTTPS_PORT})"; rc=1; fi

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
    inb=$(inbound_find "$INBOUND_REMARK") || true

    printf '\n%s================ ГОТОВО ================%s\n' "$C_GRN" "$C_OFF"
    printf '  Панель      https://%s%s\n' "$PANEL_DOMAIN" "$PANEL_BASE_PATH"
    printf '  Подписка    https://%s%s<subId>\n' "$PANEL_DOMAIN" "$PANEL_SUB_PATH"
    printf '  Прикрытие   https://%s/   (%s)\n' "$DECOY_DOMAIN" "$(state_get DECOY_BRAND)"
    printf '  Сертификаты\n'
    certs_report "$PANEL_DOMAIN" "$DECOY_DOMAIN"
    [[ $STAGING == 1 ]] && printf '  %sСертификаты тестовые (--staging). Перезапустите без флага для боевых.%s\n' "$C_YEL" "$C_OFF"
    printf '  Конфиг      %s\n  Состояние   %s\n' "$NX_CONF" "$NX_STATE"

    if [[ -n $inb ]]; then
        printf '\n  Ссылки:\n'
        inbound_print_links "$inb"
    fi
    printf '\n  Добавить пользователя:  %s add-user <имя>\n' "$NX_SELF"
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
    panel_auth
    local inb
    inb=$(inbound_find "$INBOUND_REMARK")
    [[ -n $inb ]] || die "инбаунд '$INBOUND_REMARK' не найден"
    inbound_print_links "$inb"
}

cmd_add_user() {
    local email=${1:-}
    [[ -n $email ]] || die "укажите имя пользователя: $NX_SELF add-user <имя>"
    _need_installed
    panel_auth
    local inb cid
    inb=$(inbound_find "$INBOUND_REMARK")
    [[ -n $inb ]] || die "инбаунд '$INBOUND_REMARK' не найден"
    cid=$(inbound_add_client "$inb" "$email")
    ok "клиент '$email' добавлен ($cid)"
    inb=$(inbound_find "$INBOUND_REMARK")
    # grep без совпадений уронил бы pipefail — но такого быть не должно
    inbound_links "$inb" | { grep -F -- "$cid" || true; } | while IFS= read -r l; do
        printf '\n%s\n' "$l"
        if have qrencode; then qrencode -t ANSIUTF8 -m 1 "$l" || true; fi
    done
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
        add-user)     cmd_add_user "${1:-}" ;;
        regen-decoy)  parse_args "$@"; cmd_regen_decoy ;;
        -h|--help|help) usage ;;
        *) usage; die "неизвестная команда: $cmd" ;;
    esac
}

main "$@"
