#!/usr/bin/env bash
# common.sh — пути, логирование, состояние, мелкие утилиты.
# shellcheck shell=bash

NX_PREFIX="${NX_PREFIX:-/etc/nx-revpro}"
NX_CONF="$NX_PREFIX/nxrev.conf"
NX_STATE="$NX_PREFIX/state.env"
NX_BACKUP="$NX_PREFIX/backup"

NX_WEBROOT=/var/www/nx-revpro
NX_ACME_ROOT="$NX_WEBROOT/acme"
NX_DECOY_ROOT="$NX_WEBROOT/decoy"

NX_NGINX_CONFD=/etc/nginx/conf.d
NX_NGINX_STREAM_DIR=/etc/nginx/nx-revpro/stream
NX_NGINX_MAIN=/etc/nginx/nginx.conf

XUI_DIR=/etc/x-ui
XUI_DB="$XUI_DIR/x-ui.db"
XUI_ENV="$XUI_DIR/install-result.env"
XUI_SERVICE=x-ui

NX_RUN="${NX_RUN:-/run/nx-revpro}"
NX_COOKIE="$NX_RUN/panel.cookies"

# --- язык и оформление ------------------------------------------------------

NX_LANG="${NX_LANG:-ru}"
declare -A M

i18n_load() {
    local want=${1:-$NX_LANG} file
    case $want in ru|en) ;; *) want=ru ;; esac
    NX_LANG=$want
    file="$NX_HOME/lang/${want}.sh"
    [[ -r $file ]] || { printf 'missing language file: %s\n' "$file" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$file"
}

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[38;5;203m'; C_GRN=$'\033[38;5;114m'; C_YEL=$'\033[38;5;221m'
    C_BLU=$'\033[38;5;75m';  C_DIM=$'\033[2m';        C_B=$'\033[1m'
    C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_B=""; C_OFF=""
fi

# Значки из ASCII, если терминал не в UTF-8 — иначе вместо них будет мусор.
if [[ "${LC_ALL:-}${LANG:-}" == *[Uu][Tt][Ff]* ]]; then
    S_OK="✔"; S_ERR="✖"; S_WARN="▲"; S_INFO="·"; S_STEP="▸"
else
    S_OK="+"; S_ERR="x"; S_WARN="!"; S_INFO="."; S_STEP=">"
fi

NX_STEP_NO=0
NX_STEP_TOTAL=0

banner() {
    printf '\n  %s%snx-revpro%s  %s%s%s\n' "$C_B" "$C_BLU" "$C_OFF" "$C_DIM" "${M[tagline]:-}" "$C_OFF"
    printf '  %s%s%s\n' "$C_DIM" "──────────────────────────────────────────────" "$C_OFF"
}

step() {
    NX_STEP_NO=$(( NX_STEP_NO + 1 ))
    local n=""
    (( NX_STEP_TOTAL > 0 )) && n=$(printf '%s[%d/%d]%s ' "$C_DIM" "$NX_STEP_NO" "$NX_STEP_TOTAL" "$C_OFF")
    printf '\n  %s%s%s %s%s%s%s\n' "$C_BLU" "$S_STEP" "$C_OFF" "$n" "$C_B" "$*" "$C_OFF"
}

log()   { printf '%s\n' "$*"; }
ok()    { printf '      %s%s%s %s\n' "$C_GRN" "$S_OK"   "$C_OFF" "$*"; }
info()  { printf '      %s%s %s%s\n' "$C_DIM" "$S_INFO" "$*" "$C_OFF"; }
warn()  { printf '      %s%s%s %s\n' "$C_YEL" "$S_WARN" "$C_OFF" "$*" >&2; }
err()   { printf '      %s%s%s %s\n' "$C_RED" "$S_ERR"  "$C_OFF" "$*" >&2; }
die()   { err "$*"; exit 1; }

# Пара «название — значение» в две колонки.
kv() { printf '      %s%-20s%s %s\n' "$C_DIM" "$1" "$C_OFF" "$2"; }

# То же самое, но по ключу каталога: okm <ключ> [аргументы printf]
_m()    { local k=$1; shift; printf "${M[$k]:-<$k>}" "$@"; }
okm()   { ok   "$(_m "$@")"; }
infom() { info "$(_m "$@")"; }
warnm() { warn "$(_m "$@")"; }
errm()  { err  "$(_m "$@")"; }
diem()  { die  "$(_m "$@")"; }
stepm() { step "$(_m "$@")"; }

have()  { command -v "$1" >/dev/null 2>&1; }

# --- состояние -------------------------------------------------------------
# Формат: KEY=value, по строке на ключ. Значения без переводов строк.

state_init() {
    mkdir -p "$NX_PREFIX" "$NX_BACKUP" "$NX_RUN"
    chmod 700 "$NX_PREFIX" "$NX_RUN"
    [[ -f "$NX_STATE" ]] || { : > "$NX_STATE"; chmod 600 "$NX_STATE"; }
}

state_get() {
    local k=$1
    [[ -f "$NX_STATE" ]] || return 0
    sed -n "s/^${k}=//p" "$NX_STATE" | tail -n1
}

state_set() {
    local k=$1 v=$2 tmp
    state_init
    tmp=$(mktemp)
    grep -v "^${k}=" "$NX_STATE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$k" "$v" >> "$tmp"
    cat "$tmp" > "$NX_STATE"
    rm -f "$tmp"
    chmod 600 "$NX_STATE"
}

# --- утилиты ---------------------------------------------------------------

rand_hex()  { openssl rand -hex "${1:-8}"; }
# cut, а не head -c: head закрыл бы пайп раньше времени и уронил openssl по SIGPIPE
rand_pick() { local -n _arr=$1; printf '%s' "${_arr[$((RANDOM % ${#_arr[@]}))]}"; }

# LC_ALL=C, чтобы идти по байтам: иначе не-ASCII имя клиента даст битый %-код.
urlenc() {
    local LC_ALL=C s=$1 out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c=${s:i:1}
        case $c in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

# Резервная копия файла в NX_BACKUP с меткой времени. Печатает путь копии.
backup_file() {
    local src=$1 dst
    [[ -e "$src" ]] || return 0
    mkdir -p "$NX_BACKUP"
    dst="$NX_BACKUP/$(basename "$src").$(date +%Y%m%d-%H%M%S)"
    cp -a "$src" "$dst"
    printf '%s' "$dst"
}

# tpl_render <файл> KEY VALUE [KEY VALUE ...] — шаблон читается со stdin,
# @@KEY@@ меняется на VALUE. Подстановка на чистом bash: в шаблонах nginx полно
# $-переменных и слэшей, и любой внешний sed пришлось бы экранировать.
tpl_render() {
    local out=$1; shift
    local -a keys=() vals=()
    while (( $# >= 2 )); do keys+=("$1"); vals+=("$2"); shift 2; done
    local line i mark pre post
    : > "$out"
    while IFS= read -r line || [[ -n $line ]]; do
        for (( i = 0; i < ${#keys[@]}; i++ )); do
            mark="@@${keys[i]}@@"
            # Не ${line//pat/rep}: начиная с bash 5.2 символ & в правой части
            # означает совпавший текст, и значение со знаком & подставляется
            # неверно. Склейка из двух половин от версии bash не зависит.
            while [[ $line == *"$mark"* ]]; do
                pre=${line%%"$mark"*}
                post=${line#*"$mark"}
                line=$pre${vals[i]}$post
            done
        done
        printf '%s\n' "$line" >> "$out"
    done
    chmod 644 "$out"
}

# Нормализация пути панели: всегда /xxx/ (ведущий и замыкающий слэш).
norm_path() {
    local p=${1:-/}
    [[ $p == /* ]] || p="/$p"
    [[ $p == */ ]] || p="$p/"
    printf '%s' "$p"
}

# Слушает ли кто-то addr:port (кроме процессов с именем $3).
port_taken_by() {
    local addr=$1 port=$2
    ss -lntpH 2>/dev/null | awk -v a="$addr" -v p="$port" '
        { split($4, x, ":"); pt = x[length(x)];
          ad = substr($4, 1, length($4) - length(pt) - 1);
          if (pt == p && (ad == a || ad == "*" || ad == "0.0.0.0" || ad == "[::]"))
              { print $0; exit } }'
}

# Принадлежит ли процесс указанному systemd-юниту. На systemd это надёжнее,
# чем сравнение имён: одноимённых процессов может быть несколько, и только
# cgroup говорит, кто из них наш.
pid_in_unit() {
    local pid=$1 unit=$2
    [[ -n $pid && -r /proc/$pid/cgroup ]] || return 1
    grep -q "$unit" "/proc/$pid/cgroup"
}

pid_cmdline() {
    [[ -r /proc/$1/cmdline ]] || return 1
    tr '\0' ' ' < "/proc/$1/cmdline"
}

pids_from_ss() { grep -oE 'pid=[0-9]+' <<<"$1" | cut -d= -f2 | sort -u; }

# Слушает ли кто-то ровно этот адрес и порт.
listening() { ss -lntH 2>/dev/null | awk -v a="$1:$2" '$4 == a { f = 1 } END { exit !f }'; }
