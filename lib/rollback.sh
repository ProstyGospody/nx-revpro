#!/usr/bin/env bash
# rollback.sh — откат при неудачной установке и команда удаления.
#
# Установка меняет настройки панели раньше, чем трогает nginx. Если дальше
# что-то падает, панель остаётся на loopback без проксирования — снаружи
# недоступна, и человек об этом даже не знает. Поэтому неудача возвращает БД
# из копии, сделанной перед записью.
# shellcheck shell=bash

NX_DB_BACKUP=""
NX_ROLLBACK_ARMED=0

rollback_arm()    { NX_ROLLBACK_ARMED=1; }
rollback_disarm() { NX_ROLLBACK_ARMED=0; }

panel_restore_db() {
    local bak=$1
    [[ -n $bak && -f $bak ]] || return 1
    systemctl stop "$XUI_SERVICE" >/dev/null 2>&1 || true
    cp -a "$bak" "$XUI_DB" || return 1
    systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || return 1
    return 0
}

# Вешается на EXIT: срабатывает только при ненулевом коде и только если
# настройки панели успели измениться.
rollback_on_failure() {
    local rc=$?
    (( rc == 0 )) && return 0
    apt_restore_auto_updates
    (( NX_ROLLBACK_ARMED )) || return 0
    rollback_disarm

    if [[ -z $NX_DB_BACKUP ]]; then
        infom rollback_none
        return 0
    fi
    warnm rollback_doing
    if panel_restore_db "$NX_DB_BACKUP"; then
        okm rollback_done "$NX_DB_BACKUP"
    else
        errm rollback_fail "$NX_DB_BACKUP"
    fi
}

# --- удаление ----------------------------------------------------------------
# Возвращаем систему к состоянию до установки, опираясь на те же копии,
# которые делались по ходу. Инбаунд и сертификаты не трогаем: первый заводил
# человек, вторые могут понадобиться и после удаления.
_latest_backup() {
    local pattern=$1
    find "$NX_BACKUP" -maxdepth 1 -name "$pattern" -type f 2>/dev/null \
        | sort | tail -n1
}

uninstall_all() {
    local yes=${1:-0} answer bak

    if (( ! yes )); then
        printf '  %s' "${M[uninstall_confirm]}"
        read -r answer < /dev/tty || answer=""
        case ${answer,,} in y|yes|д|да) ;; *) diem uninstall_abort ;; esac
    fi

    rm -f "$NX_NGINX_CONFD"/nx-revpro-*.conf
    rm -rf /etc/nginx/nx-revpro
    okm uninstall_nginx

    if grep -q 'nx-revpro' "$NX_NGINX_MAIN" 2>/dev/null; then
        backup_file "$NX_NGINX_MAIN" >/dev/null
        sed -i "/$(printf '%s' "$NX_MARK_BEGIN" | sed 's/[][\.*^$/]/\&/g')/,/$(printf '%s' "$NX_MARK_END" | sed 's/[][\.*^$/]/\&/g')/d" \
            "$NX_NGINX_MAIN"
        okm uninstall_stream
    fi

    bak=$(_latest_backup 'default.*')
    if [[ -n $bak && ! -e /etc/nginx/sites-enabled/default ]]; then
        cp -a "$bak" /etc/nginx/sites-enabled/default
        okm uninstall_default
    fi

    if [[ -d $NX_WEBROOT ]]; then
        rm -rf "$NX_WEBROOT"
        okm uninstall_web "$NX_WEBROOT"
    fi

    bak=$(_latest_backup 'x-ui.db.*')
    if [[ -n $bak ]] && panel_restore_db "$bak"; then
        okm uninstall_panel "$bak"
    else
        warnm uninstall_panel_skip
    fi

    nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1 || true

    infom uninstall_certs "$PANEL_DOMAIN"
    rm -rf "$NX_PREFIX"
    okm uninstall_done
}
