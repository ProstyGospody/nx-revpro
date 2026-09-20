#!/usr/bin/env bash
#
# nx-revpro — бутстрап. Запуск одной строкой:
#
#   bash <(curl -Ls https://raw.githubusercontent.com/ProstyGospody/nx-revpro/main/setup.sh)
#
# Скачивает репозиторий в /opt/nx-revpro и передаёт управление nxrev.sh install.
#
# Форма `bash <(...)`, а не `curl | bash`, выбрана намеренно: при подстановке
# процесса stdin остаётся за терминалом, поэтому скрипт может спросить домены,
# если их не передали аргументами.
set -euo pipefail

NX_REPO="${NX_REPO:-ProstyGospody/nx-revpro}"
NX_REF="${NX_REF:-main}"
NX_DEST="${NX_DEST:-/opt/nx-revpro}"
NX_LINK="${NX_LINK:-/usr/local/bin/nxrev}"

if [[ -t 1 ]]; then
    C_RED=$'\033[38;5;203m'; C_GRN=$'\033[38;5;114m'; C_YEL=$'\033[38;5;221m'
    C_BLU=$'\033[38;5;75m';  C_DIM=$'\033[2m';        C_B=$'\033[1m'
    C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_B=""; C_OFF=""
fi

step() { printf '\n  %s>%s %s%s%s\n' "$C_BLU" "$C_OFF" "$C_B" "$*" "$C_OFF"; }
ok()   { printf '      %s+%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
info() { printf '      %s. %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn() { printf '      %s!%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '      %sx%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "нужен root: sudo -i, затем повторите команду"

# --- зависимости бутстрапа -------------------------------------------------

step "Зависимости / Dependencies"
missing=()
for c in curl tar; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if (( ${#missing[@]} )); then
    info "ставлю / installing: ${missing[*]}"
    # Сразу после старта системы блокировку dpkg держит unattended-upgrades.
    # DPkg::Lock::Timeout есть с apt 2.0; на более старых просто игнорируется.
    # Сразу после старта системы блокировку dpkg держит unattended-upgrades.
    # Минуту ждём, дальше останавливаем его штатно — systemd даёт ему доделать
    # текущий пакет. Ни kill -9, ни удаления файлов блокировки: прерванная
    # посреди транзакции dpkg оставляет базу пакетов недоразобранной.
    dpkg_locked() {
        local ino
        [[ -r /proc/locks ]] || return 1
        ino=$(stat -c %i /var/lib/dpkg/lock-frontend 2>/dev/null) || return 1
        awk -v ino="$ino" '{ n = split($6, a, ":"); if (n >= 3 && a[n] == ino) exit 0 } END { exit 1 }' \
            /proc/locks
    }
    if systemctl is-active --quiet unattended-upgrades.service 2>/dev/null \
       || systemctl is-active --quiet apt-daily.service 2>/dev/null \
       || systemctl is-active --quiet apt-daily-upgrade.service 2>/dev/null \
       || dpkg_locked; then
        info "останавливаю автообновление / stopping automatic updates"
        systemctl stop unattended-upgrades.service apt-daily.service \
                       apt-daily-upgrade.service apt-daily.timer \
                       apt-daily-upgrade.timer >/dev/null 2>&1 || true
        waited=0
        while dpkg_locked && (( waited < 60 )); do sleep 2; waited=$(( waited + 2 )); done
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq "${missing[@]}" \
        || die "не смог поставить / could not install: ${missing[*]}"
fi
ok "curl и tar на месте / curl and tar are present"

# --- загрузка --------------------------------------------------------------

step "Загрузка ${NX_REPO}@${NX_REF}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

url="https://github.com/${NX_REPO}/archive/refs/heads/${NX_REF}.tar.gz"
curl -fsSL --retry 3 --max-time 120 "$url" -o "$tmp/src.tar.gz" \
    || die "не скачался $url — проверьте имя репозитория, ветку и что репозиторий публичный"

mkdir -p "$tmp/src"
tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components=1 || die "архив не распаковался"

# Проверяем, что приехало то, что ожидали, до того как что-то перезаписывать.
for f in nxrev.sh lib/common.sh lib/nginx.sh lib/panel.sh lib/inbound.sh; do
    [[ -f "$tmp/src/$f" ]] || die "в архиве нет $f — это не nx-revpro"
done
ok "распаковано $(find "$tmp/src" -type f | wc -l) файлов"

# --- установка -------------------------------------------------------------

step "Установка в $NX_DEST"
if [[ -e $NX_DEST ]]; then
    [[ -f "$NX_DEST/nxrev.sh" ]] \
        || die "$NX_DEST существует и это не nx-revpro — уберите каталог или задайте NX_DEST"
    info "обновляю существующую копию (конфиг и состояние в /etc/nx-revpro не трогаются)"
    rm -rf "$NX_DEST"
fi
mkdir -p "$(dirname "$NX_DEST")"
mv "$tmp/src" "$NX_DEST"
chmod 755 "$NX_DEST/nxrev.sh"
chmod 644 "$NX_DEST"/lib/*.sh
ln -sfn "$NX_DEST/nxrev.sh" "$NX_LINK"
ok "$NX_DEST, команда доступна как $(basename "$NX_LINK")"

# --- язык ---------------------------------------------------------------------
# Свой маленький словарь: сообщений здесь меньше десятка, а тянуть каталог из
# репозитория ради них — лишняя связанность в самом хрупком месте установки.
args=("$@")
NX_LANG="${NX_LANG:-}"
for i in "${!args[@]}"; do
    if [[ ${args[i]} == --lang && -n ${args[i+1]:-} ]]; then NX_LANG=${args[i+1]}; fi
done
[[ $NX_LANG == ru || $NX_LANG == en ]] || NX_LANG=""

interactive() { [[ -r /dev/tty ]]; }

if [[ -z $NX_LANG ]]; then
    if interactive; then
        printf '\n  %sЯзык / Language%s  [1] Русский  [2] English: ' "$C_B" "$C_OFF"
        read -r pick < /dev/tty || pick=1
        case $pick in 2|e|en|E) NX_LANG=en ;; *) NX_LANG=ru ;; esac
    else
        NX_LANG=ru
    fi
    args+=(--lang "$NX_LANG")
fi

if [[ $NX_LANG == en ]]; then
    T_DOMAINS="Domains"; T_HINT_1="Two domains, both A-records pointing at this server:"
    T_HINT_2="panel — the 3x-ui panel and subscription"
    T_HINT_3="decoy — the cover site, also the REALITY serverName"
    T_PANEL="panel domain  : "; T_DECOY="decoy domain  : "
    T_BAD="that does not look like a domain, try again"
    T_EMAIL="e-mail for Let's Encrypt (Enter to skip): "
    T_CERTS="Certificates"; T_STAGING="first run against the staging CA? [Y/n]: "
    T_STAGING_ON="issuing staging certificates; re-run with --no-staging once verified"
    T_REUSE="repeat install — CA mode comes from /etc/nx-revpro/nxrev.conf"
    T_NOTTY="--panel/--decoy are missing and there is no terminal to ask"
    T_RUN="Starting the installation"
else
    T_DOMAINS="Домены"; T_HINT_1="Нужны два домена, оба A-записью на IP этого сервера:"
    T_HINT_2="panel — панель 3x-ui и подписка"
    T_HINT_3="decoy — сайт-прикрытие, он же serverName для REALITY"
    T_PANEL="домен панели   : "; T_DECOY="домен прикрытия: "
    T_BAD="не похоже на домен, попробуйте ещё раз"
    T_EMAIL="e-mail для Let's Encrypt (Enter — пропустить): "
    T_CERTS="Сертификаты"; T_STAGING="первый прогон с тестовым CA? [Y/n]: "
    T_STAGING_ON="будут тестовые сертификаты; после проверки повторите с --no-staging"
    T_REUSE="повторная установка — режим CA берётся из /etc/nx-revpro/nxrev.conf"
    T_NOTTY="не заданы --panel/--decoy, а спросить негде (нет терминала)"
    T_RUN="Запускаю установку"
fi

# --- аргументы -------------------------------------------------------------


has_flag() {
    local needle=$1 a
    for a in "${args[@]+"${args[@]}"}"; do [[ $a == "$needle" ]] && return 0; done
    return 1
}


ask() {
    local prompt=$1 default=${2:-} reply
    read -r -p "  $prompt" reply < /dev/tty || reply=""
    printf '%s' "${reply:-$default}"
}

valid_domain() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; }

ask_domain() {
    local prompt=$1 value
    while :; do
        value=$(ask "$prompt")
        valid_domain "$value" && { printf '%s' "$value"; return 0; }
        warn "$T_BAD"
    done
}

# Спрашиваем только то, чего не передали флагами.
if ! has_flag --panel || ! has_flag --decoy; then
    interactive || die "$T_NOTTY"
    step "$T_DOMAINS"
    printf '  %s\n    %s\n    %s\n' "$T_HINT_1" "$T_HINT_2" "$T_HINT_3"
    has_flag --panel || args+=(--panel "$(ask_domain "$T_PANEL")")
    has_flag --decoy || args+=(--decoy "$(ask_domain "$T_DECOY")")
fi

if ! has_flag --email && interactive; then
    email=$(ask "$T_EMAIL")
    [[ -n $email ]] && args+=(--email "$email")
fi

# Лимит боевого CA — 5 сертификатов на домен в неделю, и сжечь его на отладке
# проще, чем кажется. На первой установке предлагаем тестовый.
if ! has_flag --staging && ! has_flag --no-staging && interactive; then
    if [[ -f /etc/nx-revpro/nxrev.conf ]]; then
        info "$T_REUSE"
    else
        step "$T_CERTS"
        answer=$(ask "$T_STAGING" y)
        case ${answer,,} in
            n|no|нет) args+=(--no-staging) ;;
            *) args+=(--staging)
               warn "$T_STAGING_ON" ;;
        esac
    fi
fi

# --- запуск ----------------------------------------------------------------

step "$T_RUN"
exec bash "$NX_DEST/nxrev.sh" install "${args[@]+"${args[@]}"}"
