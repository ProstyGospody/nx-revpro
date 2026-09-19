#!/usr/bin/env bash
# preflight.sh — проверки окружения, зависимости, определение IP и DNS.
# shellcheck shell=bash

NX_PKGS=(nginx libnginx-mod-stream certbot sqlite3 curl jq openssl ca-certificates dnsutils qrencode)

preflight_root() {
    [[ $EUID -eq 0 ]] || die "нужны права root: sudo $0 ..."
}

preflight_os() {
    [[ -r /etc/os-release ]] || die "не найден /etc/os-release — поддерживаются Debian/Ubuntu"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
        ubuntu*|debian*|*debian*) ok "ОС: ${PRETTY_NAME:-$ID}" ;;
        *) die "поддерживаются только Debian/Ubuntu (обнаружено: ${PRETTY_NAME:-$ID})" ;;
    esac
}

preflight_packages() {
    local missing=()
    local p
    for p in "${NX_PKGS[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
    done
    if (( ${#missing[@]} )); then
        info "ставлю пакеты: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" \
            || die "apt-get install не отработал: ${missing[*]}"
    fi
    ok "зависимости на месте"
}

preflight_nginx_modules() {
    local out
    out=$(nginx -V 2>&1)
    grep -q -- '--with-stream_ssl_preread_module' <<<"$out" \
        || grep -q 'ngx_stream_ssl_preread' <<<"$(ls /usr/lib/nginx/modules 2>/dev/null)" \
        || die "у nginx нет ssl_preread — поставьте nginx-full / libnginx-mod-stream"
    [[ -e /etc/nginx/modules-enabled/50-mod-stream.conf ]] \
        || warn "не вижу /etc/nginx/modules-enabled/50-mod-stream.conf; если stream не загрузится — проверьте libnginx-mod-stream"
    ok "stream + ssl_preread доступны"
}

# nginx >= 1.25.1 хочет отдельную директиву `http2 on;`, более старые —
# слово http2 в listen. Заполняет NX_HTTP2_LISTEN и NX_HTTP2_DIRECTIVE.
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
    info "nginx ${ver:-?}"
}

preflight_xui() {
    [[ -f "$XUI_DB" ]] || die "не найдена БД панели $XUI_DB — сначала установите 3x-ui (см. README)"
    systemctl list-unit-files "${XUI_SERVICE}.service" --no-legend 2>/dev/null | grep -q . \
        || die "нет systemd-юнита ${XUI_SERVICE}.service"
    local kind
    kind=$(head -c 16 "$XUI_DB" | tr -d '\0')
    [[ $kind == SQLite* ]] || die "$XUI_DB не похож на SQLite — режим MySQL не поддерживается"
    ok "3x-ui найдена, БД SQLite"
}

# --- сеть ------------------------------------------------------------------

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

# check_dns <домен> <публичный ip> — не фатально при FORCE=1
check_dns() {
    local domain=$1 public=$2 got
    got=$(resolve_a "$domain")
    if [[ -z $got ]]; then
        if [[ ${FORCE:-0} == 1 ]]; then warn "$domain: A-запись не найдена (--force)"; return 0; fi
        die "$domain: нет A-записи. Направьте домен на $public или запустите с --force"
    fi
    if [[ $got != "$public" ]]; then
        if [[ ${FORCE:-0} == 1 ]]; then warn "$domain -> $got, а сервер $public (--force)"; return 0; fi
        die "$domain указывает на $got, а не на $public. Поправьте DNS или --force"
    fi
    ok "$domain -> $got"
}

# Порты, которые должны быть свободны (либо заняты уже нашим nginx).
# Порты, которые должны быть свободны либо принадлежать нашему nginx.
# Проверять по имени процесса мало: посторонний nginx, запущенный вне
# nginx.service, тоже называется nginx, но наши конфиги ему неизвестны —
# он будет отвечать 404, пока systemd-экземпляр не может занять порт.
preflight_ports() {
    local bind=$1 hit pid
    local -a checks=("0.0.0.0 80" "$bind 443" "127.0.0.1 7443" "127.0.0.1 9443")
    local c addr port

    for c in "${checks[@]}"; do
        read -r addr port <<<"$c"
        hit=$(port_taken_by "$addr" "$port")
        [[ -z $hit ]] && continue

        pid=$(pids_from_ss "$hit" | head -1)
        if grep -q '"nginx"' <<<"$hit" && pid_in_unit "$pid" 'nginx.service'; then
            info "$addr:$port уже за nginx.service — переиспользую"
            continue
        fi

        if grep -q '"nginx"' <<<"$hit"; then
            err "$addr:$port держит nginx, не относящийся к nginx.service (pid ${pid:-?})"
            err "  команда: $(pid_cmdline "$pid" 2>/dev/null || echo '<не прочитать>')"
            err "  cgroup:  $(head -1 "/proc/$pid/cgroup" 2>/dev/null || echo '<не прочитать>')"
            err "Наши конфиги лежат в ${NX_NGINX_CONFD:-/etc/nginx/conf.d}, но этот процесс"
            err "их не читал — запросы будут получать 404, а systemd-экземпляр не сможет"
            err "занять порт (bind: Address already in use)."
            err "Остановите посторонний экземпляр и запустите install заново."
            die "$addr:$port занят чужим nginx"
        fi

        die "$addr:$port занят посторонним процессом: $(sed 's/.*users://' <<<"$hit")"
    done

    # 127.0.0.1:443 должен остаться за Xray, а не за nginx
    hit=$(ss -lntpH 2>/dev/null | awk '$4 == "127.0.0.1:443"')
    if [[ -n $hit ]] && ! grep -qE '"xray|"x-ui' <<<"$hit"; then
        die "127.0.0.1:443 занят не Xray: $(sed 's/.*users://' <<<"$hit")"
    fi
    ok "порты свободны (nginx: :80, ${bind}:443, 127.0.0.1:7443, 127.0.0.1:9443)"
}
