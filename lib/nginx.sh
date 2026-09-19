#!/usr/bin/env bash
# nginx.sh — генерация конфигов: stream-роутер по SNI + два http-бэкенда.
#
# Раскладка портов:
#   BIND_IP:443      stream, ssl_preread -> 127.0.0.1:443 (Xray REALITY)
#                                        -> 127.0.0.1:7443 (панель+подписка)
#   BIND_IP:80       ACME + редирект на https
#   127.0.0.1:7443   http/tls, proxy_protocol on  (панель)
#   127.0.0.1:9443   http/tls                      (decoy, цель REALITY)
#
# nginx слушает КОНКРЕТНЫЙ IP, а не 0.0.0.0 — иначе он займёт 127.0.0.1:443,
# который нужен Xray. Порт инбаунда = порт в share-ссылке, поэтому Xray обязан
# сидеть именно на 443.
# shellcheck shell=bash

NX_CONF_COMMON="$NX_NGINX_CONFD/nx-revpro-00-common.conf"
NX_CONF_ACME="$NX_NGINX_CONFD/nx-revpro-10-acme.conf"
NX_CONF_PANEL="$NX_NGINX_CONFD/nx-revpro-20-panel.conf"
NX_CONF_DECOY="$NX_NGINX_CONFD/nx-revpro-30-decoy.conf"
NX_CONF_STREAM="$NX_NGINX_STREAM_DIR/router.conf"

NX_MARK_BEGIN='# BEGIN nx-revpro (managed block, не редактировать)'
NX_MARK_END='# END nx-revpro'

nginx_prepare() {
    mkdir -p "$NX_NGINX_STREAM_DIR" "$NX_ACME_ROOT/.well-known/acme-challenge" "$NX_DECOY_ROOT"
    # Права выставляем явно, а не полагаемся на umask: при строгом системном
    # umask (077 на защищённых сборках) каталоги создаются с правами 700,
    # nginx не может их пройти и отдаёт 404 при существующем файле.
    find "$NX_WEBROOT" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$NX_WEBROOT" -type f -exec chmod 644 {} + 2>/dev/null || true
    chown -R www-data:www-data "$NX_WEBROOT" 2>/dev/null || true

    # Дефолтный сайт Debian слушает 0.0.0.0:80 default_server и путается под ногами.
    if [[ -L /etc/nginx/sites-enabled/default || -f /etc/nginx/sites-enabled/default ]]; then
        local bak
        bak=$(backup_file /etc/nginx/sites-enabled/default)
        rm -f /etc/nginx/sites-enabled/default
        warn "отключил /etc/nginx/sites-enabled/default (копия: $bak)"
    fi

    nginx_patch_main
}

# Верхнеуровневый блок stream{} в nginx.conf: в Debian его там нет.
nginx_patch_main() {
    if grep -q 'nx-revpro' "$NX_NGINX_MAIN"; then
        ok "nginx.conf уже подключает stream-роутер"
        return 0
    fi
    if grep -qE '^[[:space:]]*stream[[:space:]]*\{' "$NX_NGINX_MAIN"; then
        die "в $NX_NGINX_MAIN уже есть блок stream{}. Добавьте внутрь него строку:
        include ${NX_NGINX_STREAM_DIR}/*.conf;
    и перезапустите скрипт."
    fi
    local bak
    bak=$(backup_file "$NX_NGINX_MAIN")
    cat >> "$NX_NGINX_MAIN" <<PATCH

$NX_MARK_BEGIN
stream {
    include ${NX_NGINX_STREAM_DIR}/*.conf;
}
$NX_MARK_END
PATCH
    ok "в nginx.conf добавлен stream{} (копия: $bak)"
}

nginx_write_common() {
    tpl_render "$NX_CONF_COMMON" <<'TPL'
# nx-revpro: общие куски для http-серверов.
# Имя переменной уникальное, чтобы не столкнуться с чужим map $http_upgrade.
map $http_upgrade $nx_connection_upgrade {
    default upgrade;
    ''      close;
}
TPL
    ok "$(basename "$NX_CONF_COMMON")"
}

# Фаза 1: только :80. Нужен, чтобы certbot прошёл webroot ДО того, как мы
# займём 443 и начнём проксировать в ещё не существующий инбаунд.
nginx_write_acme() {
    tpl_render "$NX_CONF_ACME" \
        BIND_IP "$BIND_IP" \
        PANEL_DOMAIN "$PANEL_DOMAIN" \
        DECOY_DOMAIN "$DECOY_DOMAIN" \
        ACME_ROOT "$NX_ACME_ROOT" <<'TPL'
# nx-revpro: ACME-челленджи и редирект на https.
server {
    listen @@BIND_IP@@:80;
    server_name @@PANEL_DOMAIN@@ @@DECOY_DOMAIN@@;

    location /.well-known/acme-challenge/ {
        root @@ACME_ROOT@@;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
TPL
    ok "$(basename "$NX_CONF_ACME")"
}

NX_PROXY_PARAMS=/etc/nginx/nx-revpro/proxy-params.conf

nginx_write_proxy_params() {
    tpl_render "$NX_PROXY_PARAMS" <<'TPL'
# nx-revpro: заголовки для проксирования в 3x-ui.
proxy_http_version 1.1;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header Upgrade           $http_upgrade;
proxy_set_header Connection        $nx_connection_upgrade;
proxy_redirect off;
proxy_buffering off;
proxy_read_timeout 300s;
TPL
}

# Локации панели строятся под тот webBasePath, который уже стоит в БД.
_panel_locations() {
    local base=$PANEL_BASE_PATH
    local sub=$PANEL_SUB_PATH json=$PANEL_SUB_JSON_PATH

    printf '    location %s {\n' "$sub"
    printf '        include %s;\n' "$NX_PROXY_PARAMS"
    printf '        proxy_pass http://127.0.0.1:%s;\n    }\n\n' "$PANEL_SUB_PORT"

    if [[ $json != "$sub" ]]; then
        printf '    location %s {\n' "$json"
        printf '        include %s;\n' "$NX_PROXY_PARAMS"
        printf '        proxy_pass http://127.0.0.1:%s;\n    }\n\n' "$PANEL_SUB_PORT"
    fi

    if [[ $base != "/" ]]; then
        printf '    location = %s {\n        return 301 %s;\n    }\n\n' "${base%/}" "$base"
    fi

    printf '    location %s {\n' "$base"
    printf '        include %s;\n' "$NX_PROXY_PARAMS"
    printf '        proxy_pass http://127.0.0.1:%s;\n    }\n' "$PANEL_WEB_PORT"

    if [[ $base != "/" ]]; then
        printf '\n    # всё, что не панель и не подписка, для чужих глаз не существует\n'
        printf '    location / {\n        return 404;\n    }\n'
    fi
}

nginx_write_panel() {
    tpl_render "$NX_CONF_PANEL" \
        PANEL_DOMAIN "$PANEL_DOMAIN" \
        PANEL_HTTPS_PORT "$PANEL_HTTPS_PORT" \
        HTTP2_LISTEN "$NX_HTTP2_LISTEN" \
        HTTP2_DIRECTIVE "$NX_HTTP2_DIRECTIVE" \
        CERT "$(cert_path "$PANEL_DOMAIN")" \
        KEY "$(cert_key_path "$PANEL_DOMAIN")" \
        LOCATIONS "$(_panel_locations)" <<'TPL'
# nx-revpro: панель 3x-ui и подписка. Сюда приходит только SNI панель-домена,
# уже через stream-роутер, поэтому listen на loopback + proxy_protocol.
server {
    listen 127.0.0.1:@@PANEL_HTTPS_PORT@@ ssl@@HTTP2_LISTEN@@ proxy_protocol;
@@HTTP2_DIRECTIVE@@
    server_name @@PANEL_DOMAIN@@;

    ssl_certificate     @@CERT@@;
    ssl_certificate_key @@KEY@@;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:nxpanel:10m;
    ssl_session_timeout 1d;
    ssl_prefer_server_ciphers off;

    # Реальный IP клиента приходит в PROXY-заголовке от stream-роутера.
    set_real_ip_from 127.0.0.1;
    real_ip_header   proxy_protocol;

    client_max_body_size 64m;
    server_tokens off;
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;

@@LOCATIONS@@
}
TPL
    ok "$(basename "$NX_CONF_PANEL")"
}

nginx_write_decoy() {
    # Цель REALITY. Без proxy_protocol: сюда ходит сам Xray, а не stream-роутер.
    tpl_render "$NX_CONF_DECOY" \
        DECOY_DOMAIN "$DECOY_DOMAIN" \
        DECOY_HTTPS_PORT "$DECOY_HTTPS_PORT" \
        HTTP2_LISTEN "$NX_HTTP2_LISTEN" \
        HTTP2_DIRECTIVE "$NX_HTTP2_DIRECTIVE" \
        CERT "$(cert_path "$DECOY_DOMAIN")" \
        KEY "$(cert_key_path "$DECOY_DOMAIN")" \
        DECOY_ROOT "$NX_DECOY_ROOT" <<'TPL'
# nx-revpro: сайт-прикрытие, он же dest для REALITY.
# TLSv1.3 и h2 обязательны — REALITY отдаёт сюда рукопожатие как есть.
server {
    listen 127.0.0.1:@@DECOY_HTTPS_PORT@@ ssl@@HTTP2_LISTEN@@ default_server;
@@HTTP2_DIRECTIVE@@
    server_name @@DECOY_DOMAIN@@;

    ssl_certificate     @@CERT@@;
    ssl_certificate_key @@KEY@@;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:nxdecoy:10m;
    ssl_session_timeout 1d;
    ssl_prefer_server_ciphers off;

    root  @@DECOY_ROOT@@;
    index index.html;
    server_tokens off;
    charset utf-8;

    add_header X-Content-Type-Options nosniff always;

    location = /robots.txt { log_not_found off; access_log off; }
    location = /favicon.svg { log_not_found off; access_log off; }

    location / {
        try_files $uri $uri/ $uri.html =404;
    }
}
TPL
    ok "$(basename "$NX_CONF_DECOY")"
}

nginx_write_stream() {
    tpl_render "$NX_CONF_STREAM" \
        BIND_IP "$BIND_IP" \
        PANEL_DOMAIN "$PANEL_DOMAIN" \
        DECOY_DOMAIN "$DECOY_DOMAIN" \
        PANEL_HTTPS_PORT "$PANEL_HTTPS_PORT" \
        XRAY_PORT "$XRAY_PORT" <<'TPL'
# nx-revpro: SNI-роутер на публичном 443.
#
# default уходит в REALITY намеренно: он сам решает, что делать с чужим
# рукопожатием, и отдаёт его на decoy-сайт с настоящим сертификатом.
map $ssl_preread_server_name $nx_upstream {
    @@PANEL_DOMAIN@@  nx_panel;
    @@DECOY_DOMAIN@@  nx_reality;
    default           nx_reality;
}

upstream nx_panel   { server 127.0.0.1:@@PANEL_HTTPS_PORT@@; }
upstream nx_reality { server 127.0.0.1:@@XRAY_PORT@@; }

server {
    # Именно конкретный IP: 0.0.0.0 отобрал бы у Xray 127.0.0.1:@@XRAY_PORT@@.
    listen @@BIND_IP@@:443 reuseport;

    ssl_preread on;
    # PROXY-протокол включён для обоих бэкендов: у панели он в listen,
    # у REALITY — acceptProxyProtocol в tcpSettings.
    proxy_protocol on;

    proxy_pass $nx_upstream;
    proxy_connect_timeout 5s;
    proxy_timeout 300s;

    access_log off;
    error_log /var/log/nginx/nx-revpro-stream.log warn;
}
TPL
    ok "$(basename "$NX_CONF_STREAM")"
}

nginx_test() {
    local out
    if ! out=$(nginx -t 2>&1); then
        printf '%s\n' "$out" >&2
        die "nginx -t не прошёл"
    fi
    ok "nginx -t в порядке"
}

nginx_reload() {
    nginx_test
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx || die "nginx reload не удался"
    else
        systemctl enable --now nginx || die "nginx не стартует"
    fi
    ok "nginx перезагружен"
}

# Фаза 1: только :80, 443 ещё свободен для certbot и для того, чтобы не
# проксировать в несуществующий инбаунд.
nginx_phase_acme() {
    nginx_prepare
    nginx_write_common
    nginx_write_proxy_params
    nginx_write_acme
    # Конфиги панели и прикрытия ссылаются на сертификаты: пока их нет, nginx -t
    # не пройдёт. Если сертификаты уже есть — не снимаем :443 на повторном прогоне.
    if ! cert_exists "$PANEL_DOMAIN" || ! cert_exists "$DECOY_DOMAIN"; then
        rm -f "$NX_CONF_PANEL" "$NX_CONF_DECOY" "$NX_CONF_STREAM"
    fi
    nginx_reload
}

# Фаза 2: полный роутер. Сертификаты к этому моменту уже есть.
nginx_phase_full() {
    nginx_write_common
    nginx_write_proxy_params
    nginx_write_acme
    nginx_write_panel
    nginx_write_decoy
    nginx_write_stream
    nginx_reload
}

# nginx -t проверяет синтаксис файла, но не то, что файл вообще включён:
# если в nginx.conf нет include conf.d/*.conf, наши server-блоки просто
# не существуют для работающего процесса, а ошибок при этом нет.
nginx_assert_loaded() {
    local live
    live=$(nginx -T 2>/dev/null) || die "nginx -T не отработал"
    if ! grep -q 'nx-revpro' <<<"$live"; then
        err "работающий nginx не содержит конфигов nx-revpro"
        err "скорее всего в $NX_NGINX_MAIN нет строки:"
        err "    include ${NX_NGINX_CONFD}/*.conf;"
        die "конфиги nx-revpro не загружены"
    fi
    ok "конфиги nx-revpro загружены в nginx"
}
