#!/usr/bin/env bash
# panel.sh — чтение и запись настроек 3x-ui в SQLite.
#
# Настройки читаем и пишем прямо в БД: install-result.env устаревает, как только
# пользователь поменял порт или путь в UI, а форма "Panel Settings" умеет молча
# сбрасывать subPath. БД — источник правды, поэтому после записи перечитываем.
# shellcheck shell=bash

# Дефолты 3x-ui: строка в таблице settings появляется, только если значение
# отличается от встроенного, поэтому отсутствие ключа — это не пустая строка.
declare -A XUI_DEFAULTS=(
    [webPort]=2053         [webListen]=""        [webDomain]=""
    [webCertFile]=""       [webKeyFile]=""       [webBasePath]="/"
    [secret]=""            [sessionMaxAge]=60
    [subEnable]="false"    [subListen]=""        [subPort]=2096
    [subPath]="/sub/"      [subJsonPath]="/json/"
    [subCertFile]=""       [subKeyFile]=""       [subDomain]=""
    [subURI]=""            [subJsonURI]=""       [subUpdates]=12
)

NX_DB_SENTINEL=$'\x01'

# экранирование одинарных кавычек для SQL
sq() { local s=$1; printf '%s' "${s//\'/\'\'}"; }

db_get() {
    local k v
    k=$(sq "$1")
    v=$(sqlite3 -noheader "$XUI_DB" \
        "SELECT COALESCE((SELECT value FROM settings WHERE key='$k' LIMIT 1), char(1));") \
        || die "sqlite3: не смог прочитать settings.$1"
    if [[ $v == "$NX_DB_SENTINEL" ]]; then
        printf '%s' "${XUI_DEFAULTS[$1]-}"
    else
        printf '%s' "$v"
    fi
}

db_set() {
    local k v
    k=$(sq "$1"); v=$(sq "$2")
    sqlite3 "$XUI_DB" "
BEGIN IMMEDIATE;
UPDATE settings SET value='$v' WHERE key='$k';
INSERT INTO settings (key, value) SELECT '$k', '$v'
  WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='$k');
COMMIT;" || die "sqlite3: не смог записать settings.$1"
}

# panel_read_settings — заполняет глобальные PANEL_* из БД.
panel_read_settings() {
    PANEL_WEB_PORT=$(db_get webPort)
    PANEL_WEB_LISTEN=$(db_get webListen)
    PANEL_WEB_DOMAIN=$(db_get webDomain)
    PANEL_WEB_CERT=$(db_get webCertFile)
    PANEL_WEB_KEY=$(db_get webKeyFile)
    PANEL_BASE_PATH=$(norm_path "$(db_get webBasePath)")
    PANEL_SECRET=$(db_get secret)
    PANEL_SUB_ENABLE=$(db_get subEnable)
    PANEL_SUB_PORT=$(db_get subPort)
    PANEL_SUB_LISTEN=$(db_get subListen)
    PANEL_SUB_PATH=$(norm_path "$(db_get subPath)")
    PANEL_SUB_JSON_PATH=$(norm_path "$(db_get subJsonPath)")
}

panel_report_settings() {
    panel_read_settings
    info "webPort      = $PANEL_WEB_PORT"
    info "webListen    = ${PANEL_WEB_LISTEN:-<все интерфейсы>}"
    info "webBasePath  = $PANEL_BASE_PATH"
    info "webCertFile  = ${PANEL_WEB_CERT:-<пусто>}"
    info "webDomain    = ${PANEL_WEB_DOMAIN:-<пусто>}"
    info "subEnable    = $PANEL_SUB_ENABLE  subPort = $PANEL_SUB_PORT  subPath = $PANEL_SUB_PATH"
}

# panel_apply_settings <panel_domain> — приводит панель к виду "за nginx".
# webBasePath НЕ трогаем: nginx подстраивается под то, что выбрал пользователь.
panel_apply_settings() {
    local panel_domain=$1 bak
    panel_read_settings

    bak=$(backup_file "$XUI_DB")
    [[ -n $bak ]] && info "бэкап БД: $bak"

    systemctl stop "$XUI_SERVICE" || die "не смог остановить $XUI_SERVICE"

    # TLS терминирует nginx — панель должна отдавать чистый HTTP на loopback.
    db_set webCertFile ""
    db_set webKeyFile ""
    db_set webListen "127.0.0.1"
    # webDomain включает в панели проверку Host и ломает обращения к 127.0.0.1.
    db_set webDomain ""

    # Подписка — тем же nginx на 7443.
    db_set subEnable "true"
    db_set subListen "127.0.0.1"
    db_set subCertFile ""
    db_set subKeyFile ""
    db_set subDomain ""
    db_set subURI "https://${panel_domain}${PANEL_SUB_PATH}"
    db_set subJsonURI "https://${panel_domain}${PANEL_SUB_JSON_PATH}"

    systemctl start "$XUI_SERVICE" || die "не смог запустить $XUI_SERVICE"
    panel_wait_up || die "панель не поднялась на 127.0.0.1:${PANEL_WEB_PORT}"

    case ${PANEL_ROOT_CODE:-000} in
        200|301|302|307|308) ;;
        *) warn "корень панели отвечает $PANEL_ROOT_CODE — до проверки пароля дело ещё не дошло, а панель уже отказывает" ;;
    esac

    # Читаем обратно: 3x-ui умеет ронять subPath в "/" и терять webListen.
    local before_sub=$PANEL_SUB_PATH before_base=$PANEL_BASE_PATH bad=0
    panel_read_settings
    [[ $PANEL_WEB_LISTEN == "127.0.0.1" ]] || { err "webListen не сохранился: '$PANEL_WEB_LISTEN'"; bad=1; }
    [[ -z $PANEL_WEB_CERT && -z $PANEL_WEB_KEY ]] || { err "webCertFile/webKeyFile не очистились"; bad=1; }
    [[ -z $PANEL_WEB_DOMAIN ]] || { err "webDomain не очистился: '$PANEL_WEB_DOMAIN' — панель будет отбивать 127.0.0.1 кодом 403"; bad=1; }
    [[ $PANEL_SUB_PATH == "$before_sub" ]] || { err "subPath уехал: '$before_sub' -> '$PANEL_SUB_PATH'"; bad=1; }
    [[ $PANEL_BASE_PATH == "$before_base" ]] || { err "webBasePath уехал: '$before_base' -> '$PANEL_BASE_PATH'"; bad=1; }
    (( bad == 0 )) || die "настройки панели не применились; исходная БД лежит в $bak"

    ok "панель: http://127.0.0.1:${PANEL_WEB_PORT}${PANEL_BASE_PATH} (TLS снят, listen на loopback)"
    ok "подписка: 127.0.0.1:${PANEL_SUB_PORT}${PANEL_SUB_PATH}"
}

# Ждёт, пока панель начнёт отвечать, и запоминает HTTP-код корня в
# PANEL_ROOT_CODE. Раньше здесь был curl без -f: успехом считался любой ответ,
# в том числе 403, и «панель поднялась» печаталось, когда она уже отбивала.
# Ждёт, пока панель начнёт отвечать, и запоминает HTTP-код корня.
# Никаких "|| printf 000": curl при ошибке уже печатает 000 сам, и приписка
# давала "000000" — строку, не равную "000", отчего ожидание считалось
# успешным на первом же неудачном опросе и гонка с запуском сервиса
# маскировалась под «панель поднялась».
panel_wait_up() {
    local i code
    PANEL_ROOT_CODE=000
    for i in $(seq 1 30); do
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
               "$(panel_base_url)" 2>/dev/null) || code=000
        if [[ $code != 000 ]]; then
            PANEL_ROOT_CODE=$code
            return 0
        fi
        sleep 1
    done
    return 1
}

panel_base_url() { printf 'http://127.0.0.1:%s%s' "$PANEL_WEB_PORT" "$PANEL_BASE_PATH"; }
