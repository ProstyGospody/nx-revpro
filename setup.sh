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
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi
step() { printf '\n%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '  %s+%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
info() { printf '  %s.%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '  %sx%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "нужен root: sudo -i, затем повторите команду"

# --- зависимости бутстрапа -------------------------------------------------

step "Зависимости"
missing=()
for c in curl tar; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if (( ${#missing[@]} )); then
    info "ставлю: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" \
        || die "не смог поставить ${missing[*]}"
fi
ok "curl и tar на месте"

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

# --- аргументы -------------------------------------------------------------

args=("$@")

has_flag() {
    local needle=$1 a
    for a in "${args[@]+"${args[@]}"}"; do [[ $a == "$needle" ]] && return 0; done
    return 1
}

interactive() { [[ -r /dev/tty ]]; }

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
        warn "не похоже на домен, попробуйте ещё раз"
    done
}

# Спрашиваем только то, чего не передали флагами.
if ! has_flag --panel || ! has_flag --decoy; then
    interactive || die "не заданы --panel/--decoy, а спросить негде (нет терминала)"
    step "Домены"
    cat <<'HINT'
  Нужны два домена, оба A-записью на IP этого сервера:
    panel — панель 3x-ui и подписка
    decoy — сайт-прикрытие, он же serverName для REALITY
HINT
    has_flag --panel || args+=(--panel "$(ask_domain 'домен панели  : ')")
    has_flag --decoy || args+=(--decoy "$(ask_domain 'домен прикрытия: ')")
fi

if ! has_flag --email && interactive; then
    email=$(ask 'e-mail для Let'"'"'s Encrypt (Enter — пропустить): ')
    [[ -n $email ]] && args+=(--email "$email")
fi

# Лимит боевого CA — 5 сертификатов на домен в неделю, и сжечь его на отладке
# проще, чем кажется. На первой установке предлагаем тестовый.
if ! has_flag --staging && ! has_flag --no-staging && interactive; then
    if [[ -f /etc/nx-revpro/nxrev.conf ]]; then
        info "повторная установка — режим CA берётся из /etc/nx-revpro/nxrev.conf"
    else
        step "Сертификаты"
        answer=$(ask 'первый прогон с тестовым CA Let'"'"'s Encrypt? [Y/n]: ' y)
        case ${answer,,} in
            n|no|нет) args+=(--no-staging) ;;
            *) args+=(--staging)
               warn "будут тестовые сертификаты; после успешной проверки повторите с --no-staging" ;;
        esac
    fi
fi

# --- запуск ----------------------------------------------------------------

step "Запускаю установку"
exec bash "$NX_DEST/nxrev.sh" install "${args[@]+"${args[@]}"}"
