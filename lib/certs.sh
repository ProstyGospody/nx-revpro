#!/usr/bin/env bash
# certs.sh — выпуск и продление Let's Encrypt через webroot.
#
# Именно webroot, а не standalone: nginx уже держит :80 и останавливать его
# ради обновления нельзя. Автопродление делает штатный systemd-таймер certbot,
# мы только вешаем deploy-hook на reload nginx.
# shellcheck shell=bash

LE_LIVE=/etc/letsencrypt/live
LE_HOOK=/etc/letsencrypt/renewal-hooks/deploy/nx-revpro-reload.sh

cert_path()     { printf '%s/%s/fullchain.pem' "$LE_LIVE" "$1"; }
cert_key_path() { printf '%s/%s/privkey.pem'  "$LE_LIVE" "$1"; }

cert_exists() { [[ -s $(cert_path "$1") && -s $(cert_key_path "$1") ]]; }

cert_is_staging() {
    cert_exists "$1" || return 1
    openssl x509 -in "$(cert_path "$1")" -noout -issuer 2>/dev/null | grep -qi 'staging\|(STAGING)'
}

cert_days_left() {
    local end
    cert_exists "$1" || { printf '0'; return; }
    end=$( { openssl x509 -in "$(cert_path "$1")" -noout -enddate 2>/dev/null || true; } | cut -d= -f2 )
    [[ -n $end ]] || { printf '0'; return; }
    printf '%d' $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}

certs_install_hook() {
    mkdir -p "$(dirname "$LE_HOOK")"
    cat > "$LE_HOOK" <<'HOOK'
#!/bin/sh
# nx-revpro: перечитать сертификаты после продления.
# nginx держит и панель (:7443), и decoy-цель REALITY (:9443).
systemctl reload nginx 2>/dev/null || true
HOOK
    chmod 755 "$LE_HOOK"
    okm cert_hook "$LE_HOOK"
}

certs_check_timer() {
    if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
        okm cert_timer_ok "certbot.timer"
    elif systemctl is-enabled --quiet snap.certbot.renew.timer 2>/dev/null; then
        okm cert_timer_ok "snap.certbot.renew.timer"
    else
        warnm cert_timer_off
    fi
}

# certs_issue <домен> — идемпотентно. STAGING=1 переключает на тестовый CA.
certs_issue() {
    local domain=$1 days staged
    local -a args=(certonly --webroot -w "$NX_ACME_ROOT" -d "$domain"
                   --cert-name "$domain" --key-type ecdsa
                   --non-interactive --agree-tos --no-eff-email)

    if [[ -n ${LE_EMAIL:-} ]]; then
        args+=(-m "$LE_EMAIL")
    else
        args+=(--register-unsafely-without-email)
    fi
    [[ ${STAGING:-0} == 1 ]] && args+=(--staging)

    if cert_exists "$domain"; then
        days=$(cert_days_left "$domain")
        staged=0; cert_is_staging "$domain" && staged=1
        if [[ $staged == "${STAGING:-0}" ]] && (( days > 30 )); then
            okm cert_skip "$domain" "$days"
            return 0
        fi
        if [[ $staged != "${STAGING:-0}" ]]; then
            infom cert_switch "$domain" "$staged" "${STAGING:-0}"
            args+=(--force-renewal)
        fi
    fi

    infom cert_request "$domain" "${STAGING:-0}"
    if ! certbot "${args[@]}"; then
        # Переход с тестового CA на боевой certbot иногда не делает поверх
        # существующего сертификата. Свой же staging-сертификат удалить не
        # жалко: он всё равно не доверенный.
        if [[ ${STAGING:-0} == 0 ]] && cert_is_staging "$domain"; then
            warnm cert_retry_delete
            certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 || true
            certbot "${args[@]}" \
                || diem cert_fail "$domain"
        else
            diem cert_fail "$domain"
        fi
    fi
    cert_exists "$domain" || diem cert_missing_after "$(cert_path "$domain")"

    if [[ ${STAGING:-0} == 0 ]] && cert_is_staging "$domain"; then
        diem cert_still_staging "$domain"
    fi
    okm cert_ready "$domain" "$(cert_days_left "$domain")"
}

certs_report() {
    local d tag
    for d in "$@"; do
        if cert_exists "$d"; then
            tag=""
            cert_is_staging "$d" && tag=" ${C_YEL}[STAGING]${C_OFF}"
            infom cert_days "$d" "$(cert_days_left "$d")" "$tag"
        else
            errm cert_none "$d"
        fi
    done
}

# Проверка webroot до обращения к CA. Certbot на такой ошибке тратит попытку из
# недельного лимита, а сообщение даёт довольно глухое: кладём свой файл и
# смотрим, доезжает ли он через тот же путь, которым пойдёт валидация.
certs_selftest() {
    local domain=$1 token path code body
    token="nx-probe-$(rand_hex 12)"
    path="$NX_ACME_ROOT/.well-known/acme-challenge/$token"

    mkdir -p "$(dirname "$path")"
    printf '%s' "$token" > "$path"
    chmod 644 "$path"

    body=$(curl -sS --max-time 10 \
           --resolve "${domain}:80:${BIND_IP}" \
           "http://${domain}/.well-known/acme-challenge/${token}" 2>/dev/null) || body=""
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
           --resolve "${domain}:80:${BIND_IP}" \
           "http://${domain}/.well-known/acme-challenge/${token}" 2>/dev/null) || code=000
    rm -f "$path"

    if [[ $body == "$token" ]]; then
        okm webroot_ok "$domain"
        return 0
    fi

    errm webroot_fail "$domain" "$code"
    errm webroot_why
    errm webroot_errlog
    tail -n 3 /var/log/nginx/error.log 2>/dev/null | sed 's/^/        /' >&2 || true
    errm webroot_perms
    namei -l "$NX_ACME_ROOT/.well-known/acme-challenge" 2>/dev/null | sed 's/^/        /' >&2 || true
    return 1
}
