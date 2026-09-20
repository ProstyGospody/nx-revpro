#!/usr/bin/env bash
# Тесты чистых функций: подстановка в шаблонах, экранирование URL,
# нормализация путей, состояние и каталоги сообщений. Всё, что не требует
# ни root, ни сети, ни установленной панели.
set -uo pipefail
NX_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$NX_HOME"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NX_PREFIX="$TMP/etc"; NX_RUN="$TMP/run"
# shellcheck source=../lib/common.sh
. lib/common.sh
NX_STATE="$NX_PREFIX/state.env"; NX_BACKUP="$NX_PREFIX/backup"

pass=0; failed=0
is() {
    local got=$1 want=$2 what=$3
    if [[ $got == "$want" ]]; then
        pass=$(( pass + 1 ))
    else
        failed=$(( failed + 1 ))
        printf 'FAIL %s\n  ожидалось: %s\n  получено:  %s\n' "$what" "$want" "$got"
    fi
}

# --- norm_path ---------------------------------------------------------------
is "$(norm_path /abc/)"  "/abc/" "norm_path: уже нормальный"
is "$(norm_path abc)"    "/abc/" "norm_path: без слэшей"
is "$(norm_path /abc)"   "/abc/" "norm_path: без замыкающего"
is "$(norm_path /)"      "/"     "norm_path: корень"
is "$(norm_path '')"     "/"     "norm_path: пустая строка"

# --- urlenc ------------------------------------------------------------------
is "$(urlenc 'abc-123_~.')" 'abc-123_~.'     "urlenc: безопасные символы не трогаются"
is "$(urlenc 'a b')"        'a%20b'          "urlenc: пробел"
is "$(urlenc '/?&=#')"      '%2F%3F%26%3D%23' "urlenc: служебные символы"
is "$(urlenc 'да')"         '%D0%B4%D0%B0'   "urlenc: UTF-8 кодируется побайтово"

# --- tpl_render --------------------------------------------------------------
out="$TMP/tpl"
printf '%s\n' 'x=@@A@@ y=@@B@@' 'literal $nginx_var stays' | tpl_render "$out" A one B two
is "$(sed -n 1p "$out")" 'x=one y=two'            "tpl_render: подстановка ключей"
is "$(sed -n 2p "$out")" 'literal $nginx_var stays' "tpl_render: \$-переменные не трогаются"
printf 'no keys here\n' | tpl_render "$out"
is "$(cat "$out")" 'no keys here' "tpl_render: без пар аргументов"
printf '@@P@@\n' | tpl_render "$out" P '/a/b|c&d'
is "$(cat "$out")" '/a/b|c&d' "tpl_render: слэши и спецсимволы в значении"

# --- state -------------------------------------------------------------------
state_init
state_set FOO bar;        is "$(state_get FOO)" "bar"    "state: запись и чтение"
state_set FOO baz;        is "$(state_get FOO)" "baz"    "state: перезапись без дублей"
is "$(grep -c '^FOO=' "$NX_STATE")" "1" "state: ключ не задваивается"
is "$(state_get NOPE)" "" "state: отсутствующий ключ пуст"

# --- каталоги сообщений ------------------------------------------------------
for l in ru en; do
    i18n_load "$l"
    is "$(_m os_ok 'Ubuntu 24.04')" "$(printf "${M[os_ok]}" 'Ubuntu 24.04')" "i18n: подстановка ($l)"
    [[ -n ${M[tagline]} ]] || { printf 'FAIL i18n: пустой tagline (%s)\n' "$l"; failed=$(( failed + 1 )); }
done
i18n_load zz; is "$NX_LANG" "ru" "i18n: неизвестный язык откатывается на ru"
is "$(_m no_such_key_at_all)" "<no_such_key_at_all>" "i18n: отсутствующий ключ виден"

# --- разбор /proc/locks ------------------------------------------------------
# Формат взят с живой Ubuntu 24.04: именно так выглядит строка, когда
# unattended-upgrades держит /var/lib/dpkg/lock-frontend.
NX_APT_LOCKS=(/nonexistent)
NX_PROC_LOCKS="$TMP/locks"
# shellcheck source=../lib/preflight.sh
. lib/preflight.sh
cat > "$NX_PROC_LOCKS" <<'LOCKS'
1: POSIX  ADVISORY  WRITE 7758 08:02:2490369 0 EOF
2: FLOCK  ADVISORY  WRITE 1103 00:19:1234 0 EOF
3: POSIX  ADVISORY  READ  4242 08:02:9999999 0 EOF
LOCKS
is "$(lock_pid_for_inode 2490369)" "7758" "locks: держатель найден по inode"
is "$(lock_pid_for_inode 9999999)" "4242" "locks: другая строка"
is "$(lock_pid_for_inode 1234)"    "1103" "locks: короткий major:minor"
if lock_pid_for_inode 555 >/dev/null 2>&1; then
    printf 'FAIL locks: чужой inode не должен находиться\n'; failed=$(( failed + 1 ))
else pass=$(( pass + 1 )); fi
if lock_pid_for_inode "" >/dev/null 2>&1; then
    printf 'FAIL locks: пустой inode не должен находиться\n'; failed=$(( failed + 1 ))
else pass=$(( pass + 1 )); fi

printf '\nпройдено: %s, провалено: %s\n' "$pass" "$failed"
exit $(( failed > 0 ))
