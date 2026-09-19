#!/usr/bin/env bash
# inbound.sh — чтение и сверка инбаунда. Только чтение, из SQLite.
#
# Инбаунд создаётся руками в интерфейсе панели, а не этим скриптом. Причина
# простая: API панели меняется от версии к версии (тип tgId, формат логина,
# CSRF), и автоматическое создание ломается на каждом обновлении. Чтение же
# ограничено тремя колонками таблицы inbounds и переживает миграции.
# shellcheck shell=bash

# Все инбаунды как JSON-массив. Колонки в БД в snake_case, приводим к тем
# именам, которыми оперирует остальной код.
inbound_all() {
    sqlite3 -json "$XUI_DB" \
        "SELECT id, remark, port, listen, protocol,
                settings, stream_settings AS streamSettings
         FROM inbounds;" 2>/dev/null || printf '[]'
}

inbound_find() {
    inbound_all | jq -c --arg r "$1" 'map(select(.remark == $r)) | first // empty'
}

inbound_find_by_port() {
    inbound_all | jq -c --argjson p "$1" 'map(select(.port == $p)) | first // empty'
}

# inbound_expected_hint — что именно должно быть заведено в панели.
# inbound_expected_hint — что именно должно быть заведено в панели.
# inbound_expected_hint — что именно должно быть заведено в панели.
# Названия полей не переводятся: интерфейс 3x-ui англоязычный, и человек
# ищет глазами ровно эти подписи.
inbound_expected_hint() {
    kv "Protocol"             "VLESS"
    kv "Remark"               "$INBOUND_REMARK"
    kv "Listen IP"            "127.0.0.1"
    kv "Port"                 "$XRAY_PORT"
    kv "Flow"                 "xtls-rprx-vision"
    kv "Security"             "REALITY"
    kv "  Dest"               "127.0.0.1:${DECOY_HTTPS_PORT}"
    kv "  SNI"                "$DECOY_DOMAIN"
    kv "Transport"            "TCP"
    kv "  Proxy Protocol"     "${C_YEL}ON${C_OFF}"
    kv "Custom share address" "${C_YEL}${SHARE_ADDRESS:-$DECOY_DOMAIN}${C_OFF}"
}

# inbound_check <json> — сверяет инбаунд с тем, что настроил nginx.
# Возвращает 1, если нашлось расхождение, ломающее работу.
inbound_check() {
    local inb=$1 ss v bad=0
    ss=$(jq -r '.streamSettings // "{}"' <<<"$inb")

    v=$(jq -r '.protocol // ""' <<<"$inb")
    [[ $v == vless ]] || { errm inb_proto "$v"; bad=1; }

    v=$(jq -r '.port' <<<"$inb")
    if [[ $v != "$XRAY_PORT" ]]; then
        errm inb_port "$v" "$PUBLIC_PORT"; bad=1
    fi

    v=$(jq -r '.listen // ""' <<<"$inb")
    [[ $v == "127.0.0.1" ]] \
        || { errm inb_listen "${v:-${M[val_all_ifaces]}}"; bad=1; }

    v=$(jq -r '.tcpSettings.acceptProxyProtocol // false' <<<"$ss")
    [[ $v == true ]] \
        || { errm inb_pp; bad=1; }

    v=$(jq -r '.security // ""' <<<"$ss")
    [[ $v == reality ]] || { errm inb_sec "$v"; bad=1; }

    v=$(jq -r '.realitySettings.dest // ""' <<<"$ss")
    [[ $v == "127.0.0.1:${DECOY_HTTPS_PORT}" ]] \
        || { errm inb_dest "$v" "$DECOY_HTTPS_PORT"; bad=1; }

    v=$(jq -r '.realitySettings.serverNames[0] // ""' <<<"$ss")
    [[ $v == "$DECOY_DOMAIN" ]] \
        || { errm inb_sni "$v" "$DECOY_DOMAIN"; bad=1; }

    # Адрес в ссылке. Инбаунд слушает loopback, поэтому без явного Custom share
    # address панель подставляет произвольный адрес — ссылки из UI не работают.
    v=$(jq -r '.externalProxy[0].dest // ""' <<<"$ss")
    if [[ -z $v ]]; then
        warnm inb_share_unset
        warnm inb_share_hint "${SHARE_ADDRESS:-$DECOY_DOMAIN}"
    elif [[ $v != "${SHARE_ADDRESS:-$DECOY_DOMAIN}" ]]; then
        warnm inb_share_wrong "$v" "${SHARE_ADDRESS:-$DECOY_DOMAIN}"
    fi

    v=$(jq -r '[.settings | fromjson | .clients[]? | select(.flow != "xtls-rprx-vision")] | length' <<<"$inb" 2>/dev/null || echo 0)
    (( v == 0 )) || warnm inb_flow "$v"

    return $bad
}

# inbound_links <json> — по строке vless:// на каждого клиента.
# Порт берём из самого инбаунда: панель строит ссылку так же, и если инбаунд
# уедет с ${XRAY_PORT}, ссылка молча станет нерабочей.
inbound_links() {
    local inb=$1 ss port addr sni pbk sid fp spx remark rows uuid email flow
    ss=$(jq -r '.streamSettings // "{}"' <<<"$inb")
    port=$(jq -r '.port' <<<"$inb")
    remark=$(jq -r '.remark // "vless"' <<<"$inb")

    sni=$(jq -r '.realitySettings.serverNames[0] // empty' <<<"$ss")
    pbk=$(jq -r '.realitySettings.settings.publicKey // empty' <<<"$ss")
    sid=$(jq -r '.realitySettings.shortIds[0] // ""' <<<"$ss")
    fp=$(jq  -r '.realitySettings.settings.fingerprint // "chrome"' <<<"$ss")
    spx=$(jq -r '.realitySettings.settings.spiderX // "/"' <<<"$ss")
    addr=$(jq -r '.externalProxy[0].dest // empty' <<<"$ss")
    [[ -z $addr ]] && addr=${SHARE_ADDRESS:-$sni}

    if [[ -z $pbk ]]; then
        errm inb_nopbk
        return 1
    fi

    rows=$(jq -r '.settings | fromjson | .clients[]? | [.id, (.email // ""), (.flow // "")] | @tsv' <<<"$inb" 2>/dev/null) || rows=""
    [[ -n $rows ]] || { warnm inb_noclients; return 0; }

    while IFS=$'\t' read -r uuid email flow; do
        [[ -n $uuid ]] || continue
        printf 'vless://%s@%s:%s?type=tcp&encryption=none&security=reality&pbk=%s&fp=%s&sni=%s&sid=%s&spx=%s%s#%s\n' \
            "$uuid" "$addr" "$port" \
            "$(urlenc "$pbk")" "$(urlenc "$fp")" "$(urlenc "$sni")" \
            "$(urlenc "$sid")" "$(urlenc "$spx")" \
            "$( [[ -n $flow ]] && printf '&flow=%s' "$(urlenc "$flow")" )" \
            "$(urlenc "${remark}-${email}")"
    done <<< "$rows"
}

inbound_print_links() {
    local inb=$1 link
    while IFS= read -r link; do
        [[ -n $link ]] || continue
        printf '\n%s\n' "$link"
        if have qrencode; then qrencode -t ANSIUTF8 -m 1 "$link" || true; fi
    done < <(inbound_links "$inb")
}
