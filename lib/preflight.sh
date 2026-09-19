#!/usr/bin/env bash
# preflight.sh — проверки окружения, зависимости, определение IP и DNS.
# shellcheck shell=bash

NX_PKGS=(nginx libnginx-mod-stream certbot sqlite3 curl jq openssl ca-certificates dnsutils qrencode)

preflight_root() { [[ $EUID -eq 0 ]] || diem need_root "$0"; }

preflight_os() {
    [[ -r /etc/os-release ]] || diem no_osrelease
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
        ubuntu*|debian*|*debian*) okm os_ok "${PRETTY_NAME:-$ID}" ;;
        *) diem os_bad "${PRETTY_NAME:-${ID:-?}}" ;;
    esac
}

preflight_packages() {
    local missing=() p
    for p in "${NX_PKGS[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
    done
    if (( ${#missing[@]} )); then
        infom pkg_install "${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" \
            || diem pkg_fail "${missing[*]}"
    fi
    okm pkg_ok
}

preflight_nginx_modules() {
    nginx -V 2>&1 | grep -q -- '--with-stream_ssl_preread_module' || diem nginx_nostream
    [[ -e /etc/nginx/modules-enabled/50-mod-stream.conf ]] || warnm nginx_nomod
    okm nginx_stream_ok
}

# nginx >= 1.25.1 хочет отдельную директиву `http2 on;`, более старые — слово
# http2 в listen. Заполняет NX_HTTP2_LISTEN и NX_HTTP2_DIRECTIVE.
preflight_nginx_http2_style() {
    local ver major minor patch
    ver=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
    IFS=. read -r major minor patch <<<"${ver:-0.0.0}"
    patch=${patch:-0}
    if (( major > 1 || (major == 1 && (minor > 25 || (minor == 25 && patch >= 1))) )); then
        NX_HTTP2_LISTEN=""
        NX_HTTP2_DIRECTIVE="    http2 on;"
    else
        NX_HTTP2_LISTEN=" http2"
        NX_HTTP2_DIRECTIVE="    # http2 включён в listen (nginx ${ver})"
    fi
    infom nginx_ver "${ver:-?}"
}

preflight_xui() {
    [[ -f "$XUI_DB" ]] || diem xui_nodb "$XUI_DB"
    systemctl list-unit-files "${XUI_SERVICE}.service" --no-legend 2>/dev/null | grep -q . \
        || diem xui_nounit "$XUI_SERVICE"
    local kind
    kind=$(head -c 16 "$XUI_DB" | tr -d '\0')
    [[ $kind == SQLite* ]] || diem xui_notsqlite "$XUI_DB"
    okm xui_ok
}

# --- сеть --------------------------------------------------------------------

detect_bind_ip() {
    { ip -4 route get 1.1.1.1 2>/dev/null || true; } |
        awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

detect_public_ip() {
    local ip u
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]') || continue
        [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
    done
    return 1
}

# awk вместо grep: пустой результат не должен ронять pipefail у вызывающего
resolve_a() { dig +short A "$1" @1.1.1.1 2>/dev/null | awk '/^[0-9.]+$/ { print; exit }'; }

check_dns() {
    local domain=$1 public=$2 got
    got=$(resolve_a "$domain")
    if [[ -z $got ]]; then
        [[ ${FORCE:-0} == 1 ]] && { warnm dns_missing_force "$domain"; return 0; }
        diem dns_missing "$domain" "$public"
    fi
    if [[ $got != "$public" ]]; then
        [[ ${FORCE:-0} == 1 ]] && { warnm dns_wrong_force "$domain" "$got" "$public"; return 0; }
        diem dns_wrong "$domain" "$got" "$public"
    fi
    okm dns_ok "$domain" "$got"
}

# Порты, которые должны быть свободны либо принадлежать нашему nginx.
# Проверять по имени процесса мало: посторонний nginx, запущенный вне
# nginx.service, тоже называется nginx, но наши конфиги ему неизвестны —
# он будет отвечать 404, пока systemd-экземпляр не может занять порт.
preflight_ports() {
    local bind=$1 hit pid c addr port
    local -a checks=("0.0.0.0 80" "$bind 443" "127.0.0.1 $PANEL_HTTPS_PORT" "127.0.0.1 $DECOY_HTTPS_PORT")

    for c in "${checks[@]}"; do
        read -r addr port <<<"$c"
        hit=$(port_taken_by "$addr" "$port")
        [[ -z $hit ]] && continue

        pid=$(pids_from_ss "$hit" | head -1)
        if grep -q '"nginx"' <<<"$hit" && pid_in_unit "$pid" 'nginx.service'; then
            infom port_reuse "$addr" "$port"
            continue
        fi

        if grep -q '"nginx"' <<<"$hit"; then
            errm port_foreign_nginx "$addr" "$port" "${pid:-?}"
            errm port_foreign_cmd "$(pid_cmdline "$pid" 2>/dev/null || echo '?')"
            errm port_foreign_why
            exit 1
        fi

        diem port_busy "$addr" "$port" "$(sed 's/.*users://' <<<"$hit")"
    done

    # 127.0.0.1:443 должен остаться за Xray, а не за nginx
    hit=$(ss -lntpH 2>/dev/null | awk '$4 == "127.0.0.1:443"')
    if [[ -n $hit ]] && ! grep -qE '"xray|"x-ui' <<<"$hit"; then
        diem port_xray "$(sed 's/.*users://' <<<"$hit")"
    fi
    okm ports_ok "$bind" "$PANEL_HTTPS_PORT" "$DECOY_HTTPS_PORT"
}
