#!/usr/bin/env bash
# Русский каталог сообщений. Ключи общие с lang/en.sh — tests/check_lang.sh
# следит, чтобы наборы совпадали.
# shellcheck shell=bash disable=SC2034

M[tagline]="VLESS+REALITY за nginx SNI-роутером"

# --- окружение --------------------------------------------------------------
M[need_root]="нужны права root: sudo %s"
M[os_bad]="поддерживаются только Debian и Ubuntu (обнаружено: %s)"
M[os_ok]="ОС: %s"
M[no_osrelease]="не найден /etc/os-release — поддерживаются Debian и Ubuntu"
M[pkg_install]="ставлю пакеты: %s"
M[pkg_fail]="apt-get не смог поставить: %s"
M[pkg_ok]="зависимости на месте"
M[nginx_nostream]="у nginx нет ssl_preread — поставьте nginx-full или libnginx-mod-stream"
M[nginx_nomod]="не вижу /etc/nginx/modules-enabled/50-mod-stream.conf; если stream не загрузится, проверьте libnginx-mod-stream"
M[nginx_stream_ok]="stream и ssl_preread доступны"
M[nginx_ver]="nginx %s"
M[xui_nodb]="не найдена БД панели %s — сначала установите 3x-ui (см. README)"
M[xui_nounit]="нет systemd-юнита %s.service"
M[xui_notsqlite]="%s не похож на SQLite — режим MySQL не поддерживается"
M[xui_ok]="3x-ui найдена, БД SQLite"

# --- сеть --------------------------------------------------------------------
M[bind_unknown]="не определил IP для bind — задайте --bind-ip"
M[pub_unknown]="не смог узнать внешний IP, считаю его равным %s"
M[nat_detected]="внешний IP %s, локальный %s — похоже на NAT, слушаю локальный"
M[addr_ok]="bind %s:443, снаружи %s:%s"
M[dns_missing]="%s: нет A-записи. Направьте домен на %s или запустите с --force"
M[dns_missing_force]="%s: A-запись не найдена (--force)"
M[dns_wrong]="%s указывает на %s, а не на %s. Поправьте DNS или --force"
M[dns_wrong_force]="%s -> %s, а сервер %s (--force)"
M[dns_ok]="%s -> %s"
M[port_reuse]="%s:%s уже за nginx.service — переиспользую"
M[port_foreign_nginx]="%s:%s держит nginx, не относящийся к nginx.service (pid %s)"
M[port_foreign_cmd]="команда: %s"
M[port_foreign_why]="этот процесс не читал наши конфиги: запросы получат 404, а nginx.service не сможет занять порт"
M[port_busy]="%s:%s занят посторонним процессом: %s"
M[port_xray]="127.0.0.1:443 занят не Xray: %s"
M[ports_ok]="порты свободны (:80, %s:443, 127.0.0.1:%s, 127.0.0.1:%s)"

# --- панель -------------------------------------------------------------------
M[panel_db_backup]="копия БД: %s"
M[panel_stop_fail]="не смог остановить %s"
M[panel_start_fail]="не смог запустить %s"
M[panel_down]="панель не поднялась на 127.0.0.1:%s"
M[panel_odd_code]="корень панели отвечает %s — панель уже отказывает, до настроек дело не дошло"
M[panel_weblisten_bad]="webListen не сохранился: '%s'"
M[panel_cert_bad]="webCertFile и webKeyFile не очистились"
M[panel_domain_bad]="webDomain не очистился: '%s' — панель будет отбивать 127.0.0.1 кодом 403"
M[panel_subpath_moved]="subPath уехал: '%s' -> '%s'"
M[panel_basepath_moved]="webBasePath уехал: '%s' -> '%s'"
M[panel_apply_fail]="настройки панели не применились; исходная БД лежит в %s"
M[panel_applied]="панель: http://127.0.0.1:%s%s (TLS снят, listen на loopback)"
M[panel_sub_applied]="подписка: 127.0.0.1:%s%s"
M[sqlite_read_fail]="sqlite3: не смог прочитать settings.%s"
M[sqlite_write_fail]="sqlite3: не смог записать settings.%s"

# --- сертификаты ---------------------------------------------------------------
M[cert_hook]="deploy-hook: %s"
M[cert_timer_ok]="автопродление: %s активен"
M[cert_timer_off]="таймер certbot не включён — systemctl enable --now certbot.timer"
M[cert_skip]="сертификат %s: ещё %s дн., выпуск не нужен"
M[cert_switch]="сертификат %s меняет тип (staging=%s -> %s), перевыпускаю"
M[cert_request]="certbot: %s (staging=%s)"
M[cert_retry_delete]="не удалось перевыпустить поверх тестового — удаляю его и пробую ещё раз"
M[cert_fail]="certbot не выпустил сертификат для %s — см. /var/log/letsencrypt/letsencrypt.log"
M[cert_missing_after]="certbot отработал, но %s не появился"
M[cert_still_staging]="для %s всё ещё лежит тестовый сертификат — браузер ему не поверит"
M[cert_ready]="сертификат %s готов (осталось %s дн.)"
M[cert_none]="%s: сертификата нет"
M[cert_days]="%s: %s дн.%s"
M[staging_warn]="режим --staging: сертификаты не доверенные, только для отладки"
M[webroot_ok]="webroot для %s отдаётся корректно"
M[webroot_fail]="проверка webroot для %s не прошла: HTTP %s"
M[webroot_why]="по этому пути приходит не наш файл — запрос обслуживает другой server-блок"
M[webroot_errlog]="последние ошибки nginx:"
M[webroot_perms]="права на пути webroot:"
M[acme_blocked]="ACME-челлендж не доедет — сертификат не выпустить"

# --- nginx ----------------------------------------------------------------------
M[nginx_default_off]="отключил /etc/nginx/sites-enabled/default (копия: %s)"
M[nginx_main_patched]="в nginx.conf добавлен stream{} (копия: %s)"
M[nginx_main_ok]="nginx.conf уже подключает stream-роутер"
M[nginx_stream_exists]="в %s уже есть блок stream{}. Добавьте внутрь него: include %s/*.conf;"
M[nginx_wrote]="%s"
M[nginx_test_fail]="nginx -t не прошёл"
M[nginx_test_ok]="конфигурация nginx корректна"
M[nginx_start_fail]="nginx не стартует"
M[nginx_inactive]="nginx.service не активен после перезапуска"
M[nginx_restarted]="nginx перезапущен с новыми конфигами"
M[nginx_notloaded]="nginx.conf не включает %s/*.conf — наши блоки для nginx не существуют"
M[nginx_files_ok]="конфиги nx-revpro на месте и синтаксически верны"
M[nginx_notbound]="%s:%s ещё не занят"
M[nginx_rebind]="nginx не занял ожидаемые адреса — reload их не перепривязывает, перезапускаю"
M[nginx_bound_ok]="nginx слушает все ожидаемые адреса"
M[nginx_bind_fail]="nginx не занял нужные адреса"
M[nginx_errlog]="последние строки error.log:"

# --- прикрытие --------------------------------------------------------------------
M[decoy_kept]="прикрытие на месте: %s [%s]"
M[decoy_made]="сгенерировано прикрытие: %s [%s], основано в %s"

# --- инбаунд ----------------------------------------------------------------------
M[inb_missing]="инбаунд не найден — создайте его в панели, параметры ниже"
M[inb_port_taken]="инбаунда '%s' нет, но порт %s занят инбаундом '%s'"
M[inb_ok]="инбаунд '%s' сходится с конфигурацией nginx"
M[inb_broken]="инбаунд не сходится с конфигурацией nginx — поправьте в панели"
M[inb_proto]="протокол '%s', ожидался vless"
M[inb_port]="порт инбаунда %s, а снаружи слушается %s — share-ссылка строится именно из порта инбаунда"
M[inb_listen]="инбаунд слушает '%s', ожидалось 127.0.0.1"
M[inb_pp]="Proxy Protocol выключен, а stream-роутер его шлёт — соединения не поднимутся"
M[inb_sec]="security '%s', ожидался reality"
M[inb_dest]="realitySettings.dest '%s', ожидалось 127.0.0.1:%s"
M[inb_sni]="serverNames[0] '%s', а сертификат выписан на %s"
M[inb_flow]="у %s клиент(ов) flow не xtls-rprx-vision"
M[inb_share_unset]="не задан Custom share address — ссылки из панели будут с неверным адресом"
M[inb_share_hint]="впишите в инбаунде: %s"
M[inb_share_wrong]="Custom share address '%s', ожидался %s"
M[inb_nopbk]="у инбаунда нет publicKey — ссылку не собрать"
M[inb_noclients]="в инбаунде нет клиентов — добавьте их в панели"
M[inb_title]="Инбаунд нужно завести в панели"
M[inb_panel_at]="Панель: https://%s%s"
M[inb_notes]="Два поля легко пропустить, а без них не работает:"
M[inb_note_pp]="Proxy Protocol — stream-роутер шлёт PROXY-заголовок, без него Xray оборвёт соединение"
M[inb_note_share]="Custom share address — инбаунд на 127.0.0.1, без явного адреса панель подставит в ссылку что угодно"
M[inb_note_keys]="Ключи REALITY панель сгенерирует кнопкой Get New Cert. Flow у клиентов — xtls-rprx-vision."

# --- шаги установки ----------------------------------------------------------------
M[step_env]="Проверка окружения"
M[step_net]="Сеть и DNS"
M[step_panel_read]="Текущие настройки панели"
M[step_panel_apply]="Настройка панели под nginx"
M[step_decoy]="Сайт-прикрытие"
M[step_acme]="nginx: профиль для выпуска сертификатов"
M[step_certs]="Сертификаты Let's Encrypt"
M[step_full]="nginx: SNI-роутер"
M[step_inbound]="Инбаунд VLESS+REALITY"
M[step_verify]="Проверка"

# --- проверки ------------------------------------------------------------------------
M[v_listen_ok]="слушает %s:%s (%s)"
M[v_listen_no]="никто не слушает %s:%s (%s)"
M[v_listen_skip]="127.0.0.1:%s свободен — инбаунда ещё нет, это ожидаемо"
M[v_panel_ok]="панель через SNI-роутер отвечает 200"
M[v_panel_no]="панель по https://%s%s вернула %s"
M[v_decoy_direct_ok]="прикрытие на 127.0.0.1:%s отвечает напрямую"
M[v_decoy_direct_no]="прикрытие на 127.0.0.1:%s вернуло %s — это nginx, не REALITY"
M[v_reality_skip]="проверку REALITY пропускаю: инбаунда ещё нет"
M[v_reality_ok]="прикрытие через REALITY-fallback отвечает 200"
M[v_reality_no]="https://%s/ вернул %s — REALITY не передал соединение на :%s"
M[v_reality_hint]="частая причина: у инбаунда выключен Proxy Protocol"
M[v_cert_skip]="проверку сертификата на decoy-SNI пропускаю: соединение идёт через REALITY"
M[v_cert_ok]="на decoy-SNI отдаётся сертификат: %s"
M[v_cert_no]="на decoy-SNI пришёл не тот сертификат: %s"
M[v_partial]="часть проверок не прошла — смотрите вывод выше"

# --- итог ----------------------------------------------------------------------------
M[sum_title]="Готово"
M[sum_panel]="Панель"
M[sum_sub]="Подписка"
M[sum_decoy]="Прикрытие"
M[sum_conf]="Конфиг"
M[sum_state]="Состояние"
M[sum_links]="Ссылки"
M[sum_staging]="Сертификаты тестовые. Повторите с --no-staging для боевых."
M[sum_addmore]="Новых клиентов добавляйте в панели, затем: nxrev links"

# --- откат и удаление -----------------------------------------------------------------
M[rollback_doing]="установка прервана — возвращаю настройки панели из копии"
M[rollback_done]="настройки панели восстановлены из %s"
M[rollback_fail]="не смог восстановить БД панели; копия лежит в %s"
M[rollback_none]="настройки панели изменить не успели, откатывать нечего"
M[uninstall_confirm]="Будут удалены конфиги nginx, сайт-прикрытие и настройки nx-revpro. Продолжить? [y/N]: "
M[uninstall_abort]="отменено"
M[uninstall_nginx]="убраны конфиги nginx"
M[uninstall_stream]="блок stream{} убран из nginx.conf"
M[uninstall_web]="удалён %s"
M[uninstall_panel]="настройки панели восстановлены из %s"
M[uninstall_panel_skip]="копии БД панели нет — её настройки оставлены как есть"
M[uninstall_default]="восстановлен /etc/nginx/sites-enabled/default"
M[uninstall_certs]="сертификаты Let's Encrypt оставлены: certbot delete --cert-name %s"
M[uninstall_done]="nx-revpro удалён. Инбаунд в панели не тронут."

# --- прочее -------------------------------------------------------------------------
M[cmd_unknown]="неизвестная команда: %s"
M[arg_unknown]="неизвестный аргумент: %s (--help)"
M[arg_noval]="у %s нет значения"
M[need_panel]="не задан --panel"
M[need_decoy]="не задан --decoy"
M[same_domains]="--panel и --decoy должны различаться"
M[not_installed]="нет %s — сначала запустите install --panel ... --decoy ..."
M[inb_notfound]="инбаунд '%s' не найден"

M[val_empty]="<пусто>"
M[val_all_ifaces]="<все интерфейсы>"

M[usage]="  nxrev install --panel <домен> --decoy <домен> [--email <адрес>] [опции]
  nxrev status          проверка панели, сертификатов и всей цепочки
  nxrev links           vless://-ссылки и QR для клиентов инбаунда
  nxrev regen-decoy     пересобрать сайт-прикрытие
  nxrev uninstall       снять nx-revpro и вернуть систему как было

Опции install:
  --panel   <домен>     домен панели и подписки
  --decoy   <домен>     домен-прикрытие, он же serverName для REALITY
  --email   <адрес>     контакт для Let's Encrypt
  --bind-ip <ip>        публичный IP для nginx (по умолчанию из таблицы маршрутов)
  --share-address <хост> адрес в share-ссылке (по умолчанию decoy-домен)
  --remark  <строка>    имя инбаунда, который искать (по умолчанию nx-reality)
  --staging             тестовый CA Let's Encrypt, без расхода боевого лимита
  --no-staging          вернуться к боевому CA после отладки
  --regen-decoy         пересобрать прикрытие заново
  --force               не падать, если DNS ещё не разъехался
  --lang    ru|en       язык сообщений, запоминается в конфиге
  -y, --yes             не спрашивать подтверждение (для uninstall)
  -h, --help            эта справка

Инбаунд заводится руками в панели: API 3x-ui меняется от версии к версии.
Скрипт его находит, сверяет с конфигурацией nginx и показывает ссылки."
