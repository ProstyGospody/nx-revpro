# nx-revpro

VLESS+REALITY за nginx-роутером по SNI, поверх уже установленной панели 3x-ui.
Один публичный порт 443 отдаёт и панель, и прокси, и сайт-прикрытие.

Проверено на Ubuntu 24.04 + 3x-ui v3.6.0.

## Как это устроено

```
                                 ┌─ panel.example.com → 127.0.0.1:7443  nginx http/tls → панель :2053
клиент → IP:443 → nginx stream ──┼─ decoy.example.com → 127.0.0.1:443   Xray REALITY
          (ssl_preread)          └─ всё остальное     → 127.0.0.1:443   Xray REALITY
                                                            │
                                                fallback ───┴→ 127.0.0.1:9443  nginx http/tls → лендинг
```

* **nginx stream** на `IP:443` смотрит SNI и раскидывает соединения, не расшифровывая их.
* **`IP:443`, а не `0.0.0.0:443`** — принципиально. Иначе nginx занял бы и `127.0.0.1:443`,
  а он нужен Xray: панель берёт порт для share-ссылки прямо из порта инбаунда,
  отдельного поля «публичный порт» у неё нет. Значит инбаунд обязан жить на 443.
* **PROXY-протокол включён** на обоих направлениях: у панели через `proxy_protocol`
  в `listen`, у REALITY через `acceptProxyProtocol` в `tcpSettings`. Без этого
  реальный IP клиента терялся бы, а nginx и Xray разошлись бы по формату.
* **decoy-цель `127.0.0.1:9443`** — обычный nginx с настоящим сертификатом
  Let's Encrypt на decoy-домен. Кто пришёл без валидного VLESS-рукопожатия,
  видит живой сайт небольшой конторы, а не заглушку.

## Что нужно до запуска

1. VPS с Ubuntu 22.04/24.04 или Debian, root.
2. Два домена с A-записями на IP сервера:
   * `panel.example.com` — панель и подписка;
   * `decoy.example.com` — прикрытие и `serverName` для REALITY.
3. Свободные порты 80 и 443.
4. Установленная 3x-ui.

### Установка 3x-ui

Официальный установщик:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
```

Отвечайте так:

| Вопрос установщика | Ответ | Почему |
|---|---|---|
| тип базы данных | **SQLite** | скрипт читает и правит `/etc/x-ui/x-ui.db` напрямую; MySQL не поддерживается |
| настроить SSL сейчас | **Skip / пропустить** | сертификаты выпустит наш скрипт, TLS терминирует nginx |
| адрес прослушивания | **127.0.0.1** | наружу панель смотрит только через nginx |

Порт и путь панели выбирайте любые — скрипт прочитает их из БД и подстроит nginx.
Логин, пароль и путь установщик кладёт в `/etc/x-ui/install-result.env`; сохраните их.

## Запуск

Под root, одной строкой:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ProstyGospody/nx-revpro/main/setup.sh)
```

Скрипт скачает репозиторий в `/opt/nx-revpro`, повесит команду `nxrev` в `/usr/local/bin`
и спросит домены, e-mail и режим CA. Именно `bash <(...)`, а не `curl | bash`:
при подстановке процесса stdin остаётся за терминалом, поэтому вопросы работают.

Всё то же самое без вопросов — флаги передаются после закрывающей скобки:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ProstyGospody/nx-revpro/main/setup.sh) --panel panel.example.com --decoy decoy.example.com --email you@example.com --staging
```

Первый прогон стоит делать с `--staging`: у Let's Encrypt лимит 5 сертификатов
на домен в неделю, и на отладке его легко сжечь. Когда проверки прошли —
боевой выпуск, домены уже сохранены в конфиге:

```bash
sudo nxrev install --no-staging
```

Переменные окружения бутстрапа: `NX_REF` — ветка или тег (по умолчанию `main`),
`NX_DEST` — каталог установки (по умолчанию `/opt/nx-revpro`).

### Вручную, без бутстрапа

```bash
git clone https://github.com/ProstyGospody/nx-revpro.git && cd nx-revpro
sudo ./nxrev.sh install --panel panel.example.com --decoy decoy.example.com --email you@example.com --staging
```

### Остальные команды

```bash
sudo nxrev status          # настройки панели, сроки сертификатов, сквозная проверка
sudo nxrev links           # vless://-ссылки и QR для всех клиентов инбаунда
sudo nxrev add-user alice  # добавить клиента и сразу показать ссылку
sudo nxrev regen-decoy     # пересобрать лендинг с новым названием и нишей
```

Обновление до свежей версии — тот же однострочник: код в `/opt/nx-revpro`
перезаписывается, конфиг и состояние в `/etc/nx-revpro` не трогаются.

## Что скрипт делает с системой

| Что | Где |
|---|---|
| код скрипта и симлинк `nxrev` | `/opt/nx-revpro/`, `/usr/local/bin/nxrev` |
| свои конфиги nginx | `/etc/nginx/conf.d/nx-revpro-*.conf`, `/etc/nginx/nx-revpro/` |
| блок `stream{}` в главном конфиге | дописывается в конец `/etc/nginx/nginx.conf` между маркерами |
| дефолтный сайт Debian | отключается, копия в `/etc/nx-revpro/backup/` |
| сайт-прикрытие | `/var/www/nx-revpro/decoy/` |
| webroot для ACME | `/var/www/nx-revpro/acme/` |
| настройки панели | правятся в `/etc/x-ui/x-ui.db`, копия БД перед каждой записью |
| deploy-hook certbot | `/etc/letsencrypt/renewal-hooks/deploy/nx-revpro-reload.sh` |
| свой конфиг и состояние | `/etc/nx-revpro/nxrev.conf`, `/etc/nx-revpro/state.env` (0600) |

Автопродление сертификатов делает штатный `certbot.timer`; hook только перезагружает nginx.

### Какие настройки панели переписываются

| Ключ | Становится | Зачем |
|---|---|---|
| `webCertFile`, `webKeyFile` | пусто | TLS терминирует nginx, панель отдаёт чистый HTTP |
| `webListen` | `127.0.0.1` | снаружи панель недоступна напрямую |
| `webDomain` | пусто | иначе панель включает проверку Host и отбивает запросы на `127.0.0.1` |
| `subEnable`, `subListen` | `true`, `127.0.0.1` | подписка ходит через тот же nginx |
| `subURI`, `subJsonURI` | `https://<panel-домен>/...` | чтобы панель выдавала клиентам публичный адрес |

`webPort`, `webBasePath`, `subPath` и `subJsonPath` **не трогаются** — nginx строится под них.
Настройки читаются из БД, а не из `install-result.env`: этот файл устаревает сразу,
как только вы поменяете порт или путь в UI. Из него берётся только токен/логин для API.

## Повторный запуск

`install` идемпотентен:

* конфиги nginx и лендинг перегенерируются (лендинг — только по `--regen-decoy`,
  иначе домен на глазах наблюдателя менял бы название и нишу);
* сертификат перевыпускается только если ему осталось меньше 30 дней или сменился тип staging/боевой;
* **инбаунд не трогается вообще** — иначе перевыпустились бы ключи REALITY и отвалились клиенты.
  Скрипт только сверяет его с текущим nginx и ругается, если они разошлись;
* если сертификаты уже есть, порт 443 на время прогона не снимается.

## Грабли, на которые уже наступили

* **Порт в share-ссылке** жёстко берётся из порта инбаунда. Отдельного поля нет,
  и Custom share address задаёт только адрес. Поэтому инбаунд обязан быть на 443.
* **`subPath` иногда не сохраняется** и сбрасывается в `/`. Скрипт пишет настройки
  в БД при остановленной панели, а после старта перечитывает и падает с ошибкой,
  если значение уехало.
* **Proxy Protocol нужен не всем**: `ON` для REALITY (наш случай), `OFF` для WS и XHTTP.
  Если будете добавлять такой инбаунд руками — ему нужен отдельный маршрут в stream-роутере
  без `proxy_protocol`.
* **certbot только webroot**, не standalone: nginx уже держит `:80`, а останавливать
  его ради продления нельзя.
* **`--staging` для отладки.** Лимит боевого CA — 5 сертификатов на домен в неделю.

## Диагностика

```bash
sudo nxrev status
```

Если что-то не сходится:

```bash
sudo nginx -t                                   # синтаксис конфигов
sudo ss -lntp | grep -E ':(80|443|7443|9443|2053)'
sudo journalctl -u x-ui -n 50 --no-pager        # панель и Xray
sudo tail -n 50 /var/log/nginx/nx-revpro-stream.log
openssl s_client -connect <IP>:443 -servername decoy.example.com </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject
```

Частые причины:

* `127.0.0.1:443` слушает не Xray — значит nginx забиндился на `0.0.0.0`; проверьте `BIND_IP` в `/etc/nx-revpro/nxrev.conf`.
* REALITY не отдаёт fallback — не совпал `serverNames[0]` с decoy-доменом или `dest` смотрит не на `127.0.0.1:9443`.
* Панель отвечает 502 — `webListen` не `127.0.0.1` либо `webCertFile` не очищен и панель говорит по TLS.

## Ограничения

* Только Debian/Ubuntu, только SQLite-режим 3x-ui, только IPv4.
* Единственный транспорт — VLESS+REALITY поверх TCP с `flow=xtls-rprx-vision`.
* Удаления скрипт не умеет: снимается вручную — убрать `nx-revpro-*.conf`,
  блок между маркерами в `nginx.conf`, `/etc/nx-revpro` и `/var/www/nx-revpro`.
