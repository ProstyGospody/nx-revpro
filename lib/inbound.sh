#!/usr/bin/env bash
# inbound.sh — создание VLESS+REALITY инбаунда через API панели и сборка ссылок.
#
# Инбаунд слушает 127.0.0.1:443. Порт именно 443, потому что панель берёт порт
# для share-ссылки прямо из порта инбаунда — отдельного поля для публичного
# порта у неё нет, а Custom share address задаёт только адрес.
# shellcheck shell=bash

inbound_list() {
    local resp
    resp=$(api GET panel/api/inbounds/list) || die "не смог получить список инбаундов"
    api_ok "$resp" || die "панель вернула ошибку на inbounds/list: $(jq -r '.msg // .' <<<"$resp")"
    jq -c '.obj // []' <<<"$resp"
}

# inbound_find <remark> — печатает объект инбаунда или пусто.
inbound_find() {
    inbound_list | jq -c --arg r "$1" 'map(select(.remark == $r)) | first // empty'
}

inbound_find_by_port() {
    inbound_list | jq -c --argjson p "$1" 'map(select(.port == $p)) | first // empty'
}

# tgId у 3x-ui менял тип: до 3.8 это была строка, сейчас int64. Версию по
# API не спросить, поэтому обе формы перебираются на месте — панель сама
# скажет, какая ей подходит.
NX_TGID_FORMS=('0' '""')

# _build_client <uuid> <email> <subId> [json-значение tgId]
_build_client() {
    jq -n --arg id "$1" --arg email "$2" --arg subid "$3" --argjson tg "${4:-0}" \
        '{id:$id, flow:"xtls-rprx-vision", email:$email, limitIp:0, totalGB:0,
          expiryTime:0, enable:true, tgId:$tg, subId:$subid, reset:0}'
}

# Ошибка именно про тип tgId, а не что-то другое.
_is_tgid_type_error() {
    grep -qi 'tgId' <<<"$1" && grep -qi 'unmarshal\|cannot.*type' <<<"$1"
}

# inbound_create <email> — создаёт инбаунд, печатает id клиента.
# inbound_create <email> — создаёт инбаунд, печатает uuid клиента.
inbound_create() {
    local email=$1
    local priv pub sid1 sid2 sid3 cid subid
    read -r priv pub <<<"$(reality_keypair)"
    sid1=$(rand_hex 8); sid2=$(rand_hex 6); sid3=$(rand_hex 4)
    cid=$(uuid); subid=$(rand_alnum 16)

    local stream sniff alloc
    stream=$(jq -n \
        --arg dest "127.0.0.1:${DECOY_HTTPS_PORT}" \
        --arg sni  "$DECOY_DOMAIN" \
        --arg priv "$priv" --arg pub "$pub" \
        --arg s1 "$sid1" --arg s2 "$sid2" --arg s3 "$sid3" \
        --arg addr "${SHARE_ADDRESS:-}" --argjson pport "$PUBLIC_PORT" '
        {
          network: "tcp",
          security: "reality",
          externalProxy: (if $addr == "" then []
                          else [{forceTls:"same", dest:$addr, port:$pport, remark:""}] end),
          realitySettings: {
            show:false, xver:0,
            dest: $dest,
            serverNames: [$sni],
            privateKey: $priv,
            minClient:"", maxClient:"", maxTimediff:0,
            shortIds: [$s1, $s2, $s3],
            settings: {publicKey:$pub, fingerprint:"chrome", serverName:"", spiderX:"/"}
          },
          tcpSettings: {
            acceptProxyProtocol: true,
            header: {type:"none"}
          }
        }')

    sniff=$(jq -n '{enabled:true, destOverride:["http","tls","quic"], metadataOnly:false, routeOnly:false}')
    alloc=$(jq -n '{strategy:"always", refresh:5, concurrency:3}')

    local tg settings payload resp msg=""
    for tg in "${NX_TGID_FORMS[@]}"; do
        settings=$(jq -n --argjson c "$(_build_client "$cid" "$email" "$subid" "$tg")" \
                   '{clients:[$c], decryption:"none", fallbacks:[]}')
        payload=$(jq -n \
            --arg remark "$INBOUND_REMARK" \
            --argjson port "$XRAY_PORT" \
            --arg settings "$settings" --arg strm "$stream" \
            --arg sniff "$sniff" --arg alloc "$alloc" '
            {up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0,
             listen:"127.0.0.1", port:$port, protocol:"vless",
             settings:$settings, streamSettings:$strm, sniffing:$sniff, allocate:$alloc}')

        resp=$(api POST panel/api/inbounds/add "$payload") || die "запрос inbounds/add не прошёл"
        if api_ok "$resp"; then
            state_set REALITY_PRIVATE_KEY "$priv"
            state_set REALITY_PUBLIC_KEY  "$pub"
            ok "инбаунд '$INBOUND_REMARK' создан: vless+reality на 127.0.0.1:${XRAY_PORT}"
            printf '%s' "$cid"
            return 0
        fi

        msg=$(jq -r '.msg // .' <<<"$resp")
        if _is_tgid_type_error "$msg"; then
            info "панель ждёт другой тип tgId — повторяю"
            continue
        fi
        break
    done

    die "панель отказалась создавать инбаунд: $msg"
}

# inbound_add_client <inbound_json> <email> — печатает uuid нового клиента.
# inbound_add_client <inbound_json> <email> — печатает uuid нового клиента.
inbound_add_client() {
    local inb=$1 email=$2 id cid subid tg resp settings msg=""
    id=$(jq -r '.id' <<<"$inb")
    cid=$(uuid); subid=$(rand_alnum 16)

    for tg in "${NX_TGID_FORMS[@]}"; do
        settings=$(jq -n --argjson c "$(_build_client "$cid" "$email" "$subid" "$tg")" '{clients:[$c]}')
        resp=$(api POST panel/api/inbounds/addClient \
                 "$(jq -n --argjson id "$id" --arg s "$settings" '{id:$id, settings:$s}')") \
            || die "запрос addClient не прошёл"
        api_ok "$resp" && { printf '%s' "$cid"; return 0; }

        msg=$(jq -r '.msg // .' <<<"$resp")
        _is_tgid_type_error "$msg" && continue
        break
    done

    die "панель отказалась добавить клиента: $msg"
}

# inbound_links <inbound_json> — по строке vless:// на каждого клиента.
# Порт берём из самого инбаунда: панель строит ссылку именно так, и если
# инбаунд уедет с 443, ссылка молча станет нерабочей.
inbound_links() {
    local inb=$1 ss port addr sni pbk sid fp spx remark
    ss=$(jq -r '.streamSettings' <<<"$inb")
    port=$(jq -r '.port' <<<"$inb")
    remark=$(jq -r '.remark' <<<"$inb")

    sni=$(jq -r '.realitySettings.serverNames[0] // empty' <<<"$ss")
    pbk=$(jq -r '.realitySettings.settings.publicKey // empty' <<<"$ss")
    sid=$(jq -r '.realitySettings.shortIds[0] // ""' <<<"$ss")
    fp=$(jq  -r '.realitySettings.settings.fingerprint // "chrome"' <<<"$ss")
    spx=$(jq -r '.realitySettings.settings.spiderX // "/"' <<<"$ss")
    addr=$(jq -r '.externalProxy[0].dest // empty' <<<"$ss")
    [[ -z $addr ]] && addr=$sni

    [[ -n $pbk ]] || { err "у инбаунда нет publicKey — ссылку не собрать"; return 1; }

    local rows uuid email flow
    rows=$(jq -r '.settings | fromjson | .clients[] | [.id, .email, (.flow // "")] | @tsv' <<<"$inb")
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
        if have qrencode; then
            qrencode -t ANSIUTF8 -m 1 "$link" || true
        fi
    done < <(inbound_links "$inb")
}
