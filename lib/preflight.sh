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

# Сразу после старта системы блокировку dpkg обычно держит unattended-upgrades,
# и apt-get падает, не дождавшись её. Ждать умеет сам apt (DPkg::Lock::Timeout,
# есть начиная с apt 2.0 — Ubuntu 20.04 и Debian 11), но молча: поэтому сначала
# сами смотрим, кто держит, и говорим об этом.
NX_APT_LOCKS=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
              /var/cache/apt/archives/lock /var/lib/apt/lists/lock)
NX_APT_OPTS=(-o DPkg::Lock::Timeout=600)

# PID держателя любой из блокировок apt, через /proc/locks — без psmisc и lsof.
# Формат строки: индекс, тип, режим, rw, PID, major:minor:inode, начало, конец.
# Держатель блокировки по её inode. Формат строки /proc/locks:
#   индекс, тип, режим, rw, PID, major:minor:inode, начало, конец
# Вынесено отдельно, чтобы разбор проверялся тестом на фикстуре, а не только
# на живой системе.
NX_PROC_LOCKS="${NX_PROC_LOCKS:-/proc/locks}"

lock_pid_for_inode() {
    local ino=$1 pid
    [[ -n $ino && -r $NX_PROC_LOCKS ]] || return 1
    pid=$(awk -v ino="$ino" '
        { n = split($6, a, ":"); if (n >= 3 && a[n] == ino && $5 != "" && $5 != 0) { print $5; exit } }
    ' "$NX_PROC_LOCKS" 2>/dev/null)
    [[ -n $pid ]] || return 1
    printf '%s' "$pid"
}

# PID держателя любой из блокировок apt — без psmisc и lsof.
_apt_lock_pid() {
    local f ino pid
    for f in "${NX_APT_LOCKS[@]}"; do
        [[ -e $f ]] || continue
        ino=$(stat -c %i "$f" 2>/dev/null) || continue
        pid=$(lock_pid_for_inode "$ino") || continue
        printf '%s' "$pid"
        return 0
    done
    return 1
}

apt_wait_lock() {
    local limit=${1:-600} waited=0 pid name
    pid=$(_apt_lock_pid) || return 0

    name=$(tr -d '\0' < "/proc/$pid/comm" 2>/dev/null) || name="?"
    warnm apt_locked "${name:-?}" "$pid"

    while (( waited < limit )); do
        sleep 5
        waited=$(( waited + 5 ))
        _apt_lock_pid >/dev/null || { okm apt_lock_free "$waited"; return 0; }
        (( waited % 30 == 0 )) && infom apt_waiting "$waited"
    done

    warnm apt_lock_timeout "$limit"
    return 0
}

preflight_packages() {
    local missing=() p
    for p in "${NX_PKGS[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
    done
    (( ${#missing[@]} )) || { okm pkg_ok; return 0; }

    infom pkg_install "${missing[*]}"
    apt_wait_lock

    DEBIAN_FRONTEND=noninteractive apt-get "${NX_APT_OPTS[@]}" update -qq || true
    if ! DEBIAN_FRONTEND=noninteractive apt-get "${NX_APT_OPTS[@]}" install -y -qq "${missing[@]}"; then
        errm pkg_fail "${missing[*]}"
        errm pkg_fail_hint
        exit 1
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
