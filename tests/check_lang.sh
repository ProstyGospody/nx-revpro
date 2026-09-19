#!/usr/bin/env bash
# Наборы ключей в каталогах должны совпадать, иначе на одном языке вместо
# сообщения вылезет <ключ>. Плюс сверяем число %-подстановок: разное
# количество аргументов у одного ключа ломает printf на втором языке.
#
# Все grep обёрнуты в `|| true`: отсутствие совпадений — это не ошибка,
# а при pipefail именно так тест молча умирал бы сам.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

keys() { grep -o "^M\[[a-z0-9_]*\]" "lang/$1.sh" | tr -d 'M[]' | sort; }
fmt() {
    sed -n "s/^M\[$2\]=\"\(.*\)\"$/\1/p" "lang/$1.sh" \
        | { grep -o '%[sd]' || true; } | wc -l
}

fail=0

missing=$(comm -23 <(keys ru) <(keys en))
[[ -z $missing ]] || { printf 'нет в en:\n%s\n' "$missing"; fail=1; }
extra=$(comm -13 <(keys ru) <(keys en))
[[ -z $extra ]] || { printf 'нет в ru:\n%s\n' "$extra"; fail=1; }

while read -r k; do
    [[ -n $k ]] || continue
    a=$(fmt ru "$k"); b=$(fmt en "$k")
    [[ $a == "$b" ]] || { printf 'ключ %s: подстановок ru=%s en=%s\n' "$k" "$a" "$b"; fail=1; }
done < <(comm -12 <(keys ru) <(keys en))

# Объявленные, но нигде не используемые ключи — не ошибка, а повод убрать.
used=$( { grep -rhoE '\b(okm|infom|warnm|errm|diem|stepm|_m) [a-z0-9_]+' nxrev.sh lib/*.sh || true; } \
        | awk '{print $2}'
        { grep -rhoE 'M\[[a-z0-9_]+\]' nxrev.sh lib/*.sh || true; } | tr -d 'M[]' )
unused=0
while read -r k; do
    [[ -n $k ]] || continue
    grep -qx -- "$k" <<<"$used" || { printf 'не используется: %s\n' "$k"; unused=$(( unused + 1 )); }
done < <(keys ru)

printf 'ключей: %s, несовпадений: %s, неиспользуемых: %s\n' "$(keys ru | wc -l)" "$fail" "$unused"
exit $fail
