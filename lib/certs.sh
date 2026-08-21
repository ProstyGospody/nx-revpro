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
    ok "deploy-hook: $LE_HOOK"
}

certs_check_timer() {
    if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
        ok "автопродление: certbot.timer активен"
    elif systemctl is-enabled --quiet snap.certbot.renew.timer 2>/dev/null; then
        ok "автопродление: snap.certbot.renew.timer активен"
    else
        warn "таймер certbot не включён — 'systemctl enable --now certbot.timer'"
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
            ok "сертификат $domain: ещё $days дн., пропускаю выпуск"
            return 0
        fi
        if [[ $staged != "${STAGING:-0}" ]]; then
            info "сертификат $domain меняет тип (staging=$staged -> ${STAGING:-0}), перевыпускаю"
            args+=(--force-renewal)
        fi
    fi

    info "certbot: $domain (staging=${STAGING:-0})"
    certbot "${args[@]}" \
        || die "certbot не выпустил сертификат для $domain — смотрите /var/log/letsencrypt/letsencrypt.log"
    cert_exists "$domain" || die "certbot отработал, но $(cert_path "$domain") не появился"
    ok "сертификат $domain готов (осталось $(cert_days_left "$domain") дн.)"
}

certs_report() {
    local d
    for d in "$@"; do
        if cert_exists "$d"; then
            local tag=""
            cert_is_staging "$d" && tag=" ${C_YEL}[STAGING]${C_OFF}"
            printf '  %s.%s %s: %s дн.%s\n' "$C_DIM" "$C_OFF" "$d" "$(cert_days_left "$d")" "$tag"
        else
            err "$d: сертификата нет"
        fi
    done
}
