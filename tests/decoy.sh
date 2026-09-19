#!/usr/bin/env bash
# Дымовой тест генератора прикрытия: сайт должен собираться без остатков
# плейсхолдеров и с непустыми страницами. Прогоняем несколько раз, чтобы
# зацепить разные ниши и палитры.
set -uo pipefail
NX_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$NX_HOME"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NX_PREFIX="$TMP/etc"; NX_RUN="$TMP/run"
# shellcheck source=../lib/common.sh
. lib/common.sh
i18n_load ru
NX_STATE="$NX_PREFIX/state.env"; NX_BACKUP="$NX_PREFIX/backup"
NX_DECOY_ROOT="$TMP/decoy"
DECOY_DOMAIN="example.test"
# shellcheck source=../lib/decoy.sh
. lib/decoy.sh

state_init
failed=0
for i in 1 2 3 4 5; do
    rm -rf "$NX_DECOY_ROOT"; mkdir -p "$NX_DECOY_ROOT"
    : > "$NX_STATE"
    decoy_generate 1 >/dev/null 2>&1

    for f in index.html privacy.html terms.html robots.txt favicon.svg assets/site.css; do
        if [[ ! -s "$NX_DECOY_ROOT/$f" ]]; then
            printf 'FAIL прогон %s: нет или пуст %s\n' "$i" "$f"; failed=1
        fi
    done
    if grep -rq '@@' "$NX_DECOY_ROOT" 2>/dev/null; then
        printf 'FAIL прогон %s: остались плейсхолдеры\n' "$i"
        grep -rno '@@[A-Z_]*@@' "$NX_DECOY_ROOT" | head -3
        failed=1
    fi
    if grep -rqF '${' "$NX_DECOY_ROOT" 2>/dev/null; then
        printf 'FAIL прогон %s: остались неподставленные переменные\n' "$i"; failed=1
    fi
    grep -q '<title>' "$NX_DECOY_ROOT/index.html" || { printf 'FAIL прогон %s: нет title\n' "$i"; failed=1; }
done

(( failed )) || printf 'прикрытие собирается корректно (5 прогонов)\n'
exit $failed
