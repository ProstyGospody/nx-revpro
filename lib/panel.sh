#!/usr/bin/env bash
# panel.sh — чтение/запись настроек 3x-ui в SQLite и доступ к HTTP API панели.
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

# --- учётные данные --------------------------------------------------------
# install-result.env нужен только ради токена/логина. Имена ключей у разных
# сборок 3x-ui разъезжаются, поэтому подбираем по списку кандидатов.

# Пароль берём у самой панели, а не из install-result.env: тот файл пишется
# один раз при установке и устаревает, как только пароль сменили в UI.
# Таблица users — то же самое, что показывает `x-ui setting -show true`.
_creds_from_db() {
    local row u p
    row=$(sqlite3 -noheader -separator '|' "$XUI_DB" \
          "SELECT username, password FROM users ORDER BY id LIMIT 1;" 2>/dev/null) || return 1
    u=${row%%|*}; p=${row#*|}
    [[ -n $u && -n $p && $u != "$row" ]] || return 1

    # Свежие сборки хранят хеш. Исходный пароль из него не достать.
    case $p in
        '$2a$'*|'$2b$'*|'$2y$'*|'$argon2'*|'$pbkdf2'*) NX_PASS_HASHED=1; return 2 ;;
    esac
    PANEL_USER=$u
    PANEL_PASS=$p
    return 0
}

# Запасной источник: файл, который установщик 3x-ui пишет один раз.
_creds_from_env() {
    [[ -r $XUI_ENV ]] || return 1
    local line k v lk
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*# ]] && continue
        [[ $line == *=* ]] || continue
        k=${line%%=*}; v=${line#*=}
        k=$(tr -d '[:space:]' <<<"$k")
        v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
        lk=$(tr '[:upper:]' '[:lower:]' <<<"$k" | tr -d '_-')
        case $lk in
            token|apitoken|xuitoken|accesstoken|paneltoken)
                [[ -z ${PANEL_TOKEN:-} ]] && PANEL_TOKEN=$v ;;
            username|user|login|xuiusername|panelusername)
                [[ -z ${PANEL_USER:-} ]] && PANEL_USER=$v ;;
            password|pass|xuipassword|panelpassword)
                [[ -z ${PANEL_PASS:-} ]] && PANEL_PASS=$v ;;
        esac
    done < "$XUI_ENV"
    [[ -n ${PANEL_USER:-} && -n ${PANEL_PASS:-} ]]
}

panel_load_credentials() {
    PANEL_TOKEN="${PANEL_TOKEN:-}"
    PANEL_USER="${PANEL_USER:-}"
    PANEL_PASS="${PANEL_PASS:-}"
    NX_PASS_HASHED=0

    if [[ -n $PANEL_TOKEN || ( -n $PANEL_USER && -n $PANEL_PASS ) ]]; then
        info "учётные данные: заданы в $NX_CONF"
        return 0
    fi

    local rc=0
    _creds_from_db || rc=$?
    case $rc in
        0) info "учётные данные: из БД панели, пользователь '$PANEL_USER'"; return 0 ;;
        2) warn "пароль в БД хранится хешем — исходный из него не восстановить" ;;
    esac

    # При хешированном пароле сам пароль не менялся, только способ хранения,
    # поэтому значение из install-result.env ещё может подойти.
    if _creds_from_env; then
        if (( NX_PASS_HASHED )); then
            info "учётные данные: из $(basename "$XUI_ENV") (проверить по БД нельзя)"
        else
            warn "учётные данные: из $(basename "$XUI_ENV") — этот файл мог устареть"
        fi
        return 0
    fi

    return 0
}

panel_base_url() { printf 'http://127.0.0.1:%s%s' "$PANEL_WEB_PORT" "$PANEL_BASE_PATH"; }

# Подсказка, общая для всех случаев «панель не пустила».
_auth_probe() {
    err ""
    if (( ${NX_PASS_HASHED:-0} )); then
        err "Пароль в БД хранится хешем, поэтому он взят из $(basename "$XUI_ENV")"
        err "и, судя по всему, устарел."
    else
        err "Логин и пароль взяты из БД панели, но она их не приняла."
    fi
    err ""
    err "Что посмотреть:"
    err "  1. Что показывает сама панель:"
    err "       x-ui setting -show true"
    err "  2. Включён ли второй фактор:"
    err "       sqlite3 $XUI_DB \"select key, value from settings where key like '%woFactor%'\""
    err ""
    err "Задать заведомо рабочий пароль (панель умеет сама):"
    err "       x-ui setting -username НОВЫЙ_ЛОГИН -password НОВЫЙ_ПАРОЛЬ"
    err "Либо прописать существующий в конфиг:"
    err "       echo 'PANEL_USER=логин'  >> $NX_CONF"
    err "       echo 'PANEL_PASS=пароль' >> $NX_CONF"
    err ""
    err "Если включён второй фактор — его придётся выключить на время установки:"
    err "скрипт ходит в API без участия человека и TOTP-код взять неоткуда."
    err ""
    err "Панель сейчас слушает только loopback. Открыть её можно туннелем:"
    err "    ssh -L ${PANEL_WEB_PORT}:127.0.0.1:${PANEL_WEB_PORT} root@<ip-сервера>"
    err "    затем http://127.0.0.1:${PANEL_WEB_PORT}${PANEL_BASE_PATH}"
}

# POST формы с возвратом HTTP-кода. Без -f: код и тело нужны для диагностики,
# а -f их как раз и прячет.
# POST формы с возвратом HTTP-кода. Без -f: код и тело нужны для диагностики,
# а -f их как раз и прячет. Код забираем в переменную, а не дописываем запасной
# через ||: curl при ошибке уже напечатал "000", и получалось "000000".
# POST формы с возвратом HTTP-кода. Без -f: код и тело нужны для диагностики,
# а -f их как раз и прячет. Код забираем в переменную, а не дописываем запасной
# через ||: curl при ошибке уже напечатал "000", и получалось "000000".
# stderr curl сохраняем — при коде 000 только там и написано, что случилось.
# POST формы. Результат кладётся в глобальные NX_HTTP_CODE / NX_CURL_RC /
# NX_CURL_ERR, а не печатается: вызов через $( ) уводил бы всё в подоболочку,
# и наружу не попадала даже причина ошибки.
# Без -f — код и тело нужны для диагностики, а -f их прячет.
_post_form() {
    local url=$1 out=$2; shift 2
    local errf="$NX_RUN/curl.err"

    : > "$errf" 2>/dev/null || errf=/dev/null
    if NX_HTTP_CODE=$(curl -sS -o "$out" -w '%{http_code}' --max-time 15 "$@" "$url" 2>"$errf"); then
        NX_CURL_RC=0
    else
        NX_CURL_RC=$?
    fi
    NX_CURL_ERR=$(tr -d '\r' < "$errf" 2>/dev/null | head -c 200 || true)
    [[ $errf != /dev/null ]] && rm -f "$errf"
    NX_HTTP_CODE=${NX_HTTP_CODE:-000}
}

# Одна попытка логина. secret_field — под каким именем отправить secret-токен
# (у разных сборок 3x-ui это loginSecret или secret), пусто — не отправлять.
# Заголовки, которые шлёт сам веб-интерфейс панели. Свежие сборки 3x-ui
# отбивают POST без Origin/Referer силами CSRF-middleware — до обработчика,
# поэтому в журнале сервиса не остаётся ни строчки, а наружу летит голый 403.
_panel_headers() {
    NX_HDR=(-H "Origin: http://127.0.0.1:${PANEL_WEB_PORT}"
            -H "Referer: $(panel_base_url)"
            -H "X-Requested-With: XMLHttpRequest"
            -H "Accept: application/json, text/plain, */*")
}

# Одна попытка логина. secret_field — под каким именем отправить secret-токен
# (у разных сборок 3x-ui это loginSecret или secret), пусто — не отправлять.
# Браузер перед логином сначала грузит страницу панели: получает сессионную
# куку и CSRF-токен. Свежие 3x-ui без этого отдают на POST голый 403 с
# Content-Length: 0 и ничего не пишут в журнал. Повторяем тот же порядок.
_b64url_d() {
    local s=$1 pad
    s=${s//-/+}; s=${s//_//}
    pad=$(( ${#s} % 4 ))
    (( pad )) && s+=$(printf '=%.0s' $(seq $(( 4 - pad ))))
    printf '%s' "$s" | base64 -d 2>/dev/null || true
}

# CSRF_TOKEN лежит открытым текстом внутри сессионной куки 3x-ui. Она устроена
# как gorilla/sessions: base64url("<unix-время>|base64url(gob)|<hmac>"), а в gob
# записана пара CSRF_TOKEN -> значение. Подписано, но не зашифровано, поэтому
# читается без ключа.
_csrf_from_cookie() {
    local raw outer mid
    # HttpOnly-куки curl пишет строкой "#HttpOnly_<домен>", поэтому отбрасывать
    # всё, что начинается с #, нельзя — именно так терялась нужная кука.
    raw=$(awk -F'\t' 'NF >= 7 && $6 ~ /^(3x-ui|x-ui|session)$/ { print $7 }' \
          "$NX_COOKIE" 2>/dev/null | tail -1)
    [[ -n $raw ]] || return 1
    outer=$(_b64url_d "$raw")
    [[ $outer == *"|"* ]] || return 1
    mid=$(cut -d'|' -f2 <<<"$outer")
    [[ -n $mid ]] || return 1
    _b64url_d "$mid" | tr -c 'A-Za-z0-9_-' '\n' \
        | grep -A4 -x 'CSRF_TOKEN' \
        | grep -xE '[A-Za-z0-9_-]{20,}' | head -1
}

# Браузер перед логином грузит страницу панели и получает сессионную куку с
# CSRF-токеном. Свежие 3x-ui без него отдают на POST голый 403 с
# Content-Length: 0 и ничего не пишут в журнал. Повторяем тот же порядок.
_prime_session() {
    local gcode
    rm -f "$NX_COOKIE"
    _panel_headers
    gcode=$(curl -sS -c "$NX_COOKIE" -o /dev/null -w '%{http_code}' --max-time 10 \
            "$(panel_base_url)" 2>/dev/null) || gcode=000
    info "страница панели: HTTP ${gcode:-000}"

    NX_CSRF=$(_csrf_from_cookie || true)
    if [[ -n ${NX_CSRF:-} ]]; then
        info "CSRF-токен получен из сессионной куки"
    else
        warn "CSRF-токен не нашёлся в куке"
        if [[ ! -s $NX_COOKIE ]]; then
            warn "  файл кук $NX_COOKIE пуст: GET страницы панели не отдал Set-Cookie"
        else
            warn "  куки в jar: $(awk -F'\t' 'NF >= 7 { printf "%s ", $6 }' "$NX_COOKIE")"
        fi
    fi
    return 0
}

# Одна попытка логина. secret_field — под каким именем отправить secret-токен
# (у разных сборок 3x-ui это loginSecret или secret), пусто — не отправлять.
_try_login() {
    local secret_field=$1 out=$2
    _prime_session
    local -a args=(-b "$NX_COOKIE" -c "$NX_COOKIE" "${NX_HDR[@]}"
                   --data-urlencode "username=$PANEL_USER"
                   --data-urlencode "password=$PANEL_PASS")
    [[ -n ${NX_CSRF:-} ]] && args+=(-H "X-CSRF-Token: $NX_CSRF" -H "X-XSRF-TOKEN: $NX_CSRF")
    [[ -n ${NX_CSRF:-} ]] && args+=(--data-urlencode "_csrf=$NX_CSRF")
    [[ -n $secret_field && -n ${PANEL_SECRET:-} ]] \
        && args+=(--data-urlencode "${secret_field}=$PANEL_SECRET")
    _post_form "$(panel_base_url)login" "$out" "${args[@]}"
}

# Подбирает рабочий способ аутентификации: PANEL_AUTH = token | cookie.
# Между правкой настроек и логином панель успевает перезапуститься, а то и
# упасть. Раньше скрипт ломился в неё вслепую и печатал «не тот пароль»,
# хотя на порту никого не было.
_ensure_panel_alive() {
    panel_wait_up && [[ ${PANEL_ROOT_CODE:-000} != 000 ]] && return 0

    err "на 127.0.0.1:${PANEL_WEB_PORT} никто не слушает — логиниться некуда"
    err "systemctl is-active $XUI_SERVICE: $(systemctl is-active "$XUI_SERVICE" 2>/dev/null || true)"
    err "последние строки журнала:"
    journalctl -u "$XUI_SERVICE" -n 15 --no-pager 2>/dev/null | sed 's/^/      /' >&2 || true
    return 1
}

panel_auth() {
    panel_load_credentials
    mkdir -p "$NX_RUN"; chmod 700 "$NX_RUN"
    _ensure_panel_alive || die "панель не отвечает — до аутентификации дело не дошло"
    local base; base=$(panel_base_url)

    if [[ -n ${PANEL_TOKEN:-} ]]; then
        if curl -fsS -o /dev/null --max-time 8 \
             -H "Authorization: Bearer $PANEL_TOKEN" \
             "${base}panel/api/inbounds/list" 2>/dev/null; then
            PANEL_AUTH=token; ok "API: токен из $(basename "$XUI_ENV")"; return 0
        fi
        warn "токен из $XUI_ENV не подошёл — пробую логин и пароль"
    fi

    if [[ -z ${PANEL_USER:-} || -z ${PANEL_PASS:-} ]]; then
        err "в $XUI_ENV не нашлось ни токена, ни пары логин/пароль"
        _auth_probe
        die "нет доступа к API панели"
    fi

    # Если secret-токен задан, перебираем имена поля: разные сборки 3x-ui ждут
    # его как loginSecret или как secret. Последняя попытка — вовсе без него.
    local out="$NX_RUN/login.out" code=000 body="" field="" used=""
    local -a variants
    if [[ -n ${PANEL_SECRET:-} ]]; then
        variants=(loginSecret secret "")
        info "в настройках панели задан secret-токен — отправляю его при логине"
    else
        variants=("")
    fi

    for field in "${variants[@]}"; do
        _try_login "$field" "$out"
        code=$NX_HTTP_CODE
        body=$(head -c 400 "$out" 2>/dev/null || true)
        used=${field:-без secret}

        if [[ $code == 200 || $code == 204 ]] \
           && [[ $(jq -r '.success // false' <<<"$body" 2>/dev/null) == true ]]; then
            rm -f "$out"
            chmod 600 "$NX_COOKIE"
            PANEL_AUTH=cookie
            # после входа сессия пересоздаётся — токен берём заново
            NX_CSRF=$(_csrf_from_cookie || true)
            ok "API: сессия под пользователем $PANEL_USER (secret как '$used')"
            return 0
        fi

        info "попытка '$used' -> HTTP $code"
        # Панель не отвечает вовсе — перебирать поля бессмысленно.
        [[ $code == 000 ]] && break
    done
    rm -f "$out"

    if [[ $code == 200 ]] && jq -e '.success == false' <<<"$body" >/dev/null 2>&1; then
        err "панель приняла запрос и отвергла учётные данные:"
        err "    $(jq -r '.msg // .' <<<"$body")"
        err "Сессия и CSRF при этом работают — дело только в логине или пароле."
    else
        err "панель не пустила: последний ответ HTTP $code на ${base}login"
        [[ -n $body ]] && err "тело ответа: $body"
    fi

    case $code in
        000)
            err "curl завершился с кодом ${NX_CURL_RC:-?} (28 — таймаут, 7 — отказ в соединении, 52 — пустой ответ, 56 — обрыв)"
            [[ -n ${NX_CURL_ERR:-} ]] && err "curl сказал: $NX_CURL_ERR"
            err "Это не про пароль. Проверьте, жива ли панель:"
            err "    systemctl status $XUI_SERVICE --no-pager"
            err "    ss -lntp | grep ${PANEL_WEB_PORT}"
            err "    curl -sS -o /dev/null -w '%{http_code}\n' -m 5 $(panel_base_url)"
            err "Если корень отвечает, а login висит — панель могла забанить"
            err "адрес после неудачных попыток: journalctl -u $XUI_SERVICE -n 50 --no-pager" ;;
        403)
            err "403 отдаёт не проверка пароля, а middleware панели."
            _auth_probe ;;
        401)
            err "логин или пароль не подошли"
            _auth_probe ;;
        404)
            err "не сходится webBasePath. Что реально лежит в БД:"
            err "    sqlite3 $XUI_DB \"select value from settings where key='webBasePath'\"" ;;
        *)
            _auth_probe ;;
    esac
    die "не удалось получить доступ к API панели"
}

# api <GET|POST> <путь относительно base> [json-тело]
# api <GET|POST> <путь относительно base> [json-тело]
api() {
    local method=$1 path=$2 data=${3:-}
    _panel_headers
    local -a args=(-fsS --max-time 20 -X "$method" "${NX_HDR[@]}")

    case ${PANEL_AUTH:-} in
        token)  args+=(-H "Authorization: Bearer $PANEL_TOKEN") ;;
        cookie) args+=(-b "$NX_COOKIE" -c "$NX_COOKIE") ;;
        *)      die "panel_auth не вызывался" ;;
    esac

    # CSRF-защита распространяется на все изменяющие запросы, не только логин.
    [[ -n ${NX_CSRF:-} ]] && args+=(-H "X-CSRF-Token: $NX_CSRF" -H "X-XSRF-TOKEN: $NX_CSRF")
    [[ -n $data ]] && args+=(-H 'Content-Type: application/json' --data-binary "$data")

    curl "${args[@]}" "$(panel_base_url)${path}" 2>/dev/null
}

api_ok() { [[ $(jq -r '.success // false' <<<"$1" 2>/dev/null) == true ]]; }

# Пара ключей REALITY: сначала эндпоинтом панели, потом бинарником Xray.
reality_keypair() {
    local resp priv pub bin out
    resp=$(api POST server/getNewX25519Cert "" 2>/dev/null) || resp=""
    if api_ok "$resp"; then
        priv=$(jq -r '.obj.privateKey // empty' <<<"$resp")
        pub=$(jq -r '.obj.publicKey // empty' <<<"$resp")
        [[ -n $priv && -n $pub ]] && { printf '%s %s' "$priv" "$pub"; return 0; }
    fi
    bin=$( { find /usr/local/x-ui/bin -maxdepth 1 -type f -name "xray-*" ! -name "*.dat" 2>/dev/null || true; } | head -n1 )
    [[ -n $bin && -x $bin ]] || die "не смог сгенерировать ключи REALITY (ни API, ни бинарника xray)"
    # Разные версии Xray печатают Private key: / PrivateKey: / Password: —
    # берём последнее поле первых двух строк.
    out=$("$bin" x25519) || die "xray x25519 завершился с ошибкой"
    priv=$(sed -n '1p' <<<"$out" | awk '{print $NF}')
    pub=$(sed -n '2p'  <<<"$out" | awk '{print $NF}')
    [[ -n $priv && -n $pub ]] || die "не разобрал вывод xray x25519: $out"
    printf '%s %s' "$priv" "$pub"
}
