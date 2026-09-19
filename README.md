<div align="center">

<img src="assets/logo.svg" alt="nx-revpro" width="88">

# nx-revpro

**VLESS + REALITY за nginx SNI-роутером.**
Панель, прокси и сайт-прикрытие делят один публичный порт 443.

![bash](https://img.shields.io/badge/bash-5.x-2f6df6?logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/Ubuntu%2022.04%20%7C%2024.04%20%7C%20Debian-0e9aa7?logo=ubuntu&logoColor=white)
![3x-ui](https://img.shields.io/badge/3x--ui-v3.6.0-555)
![transport](https://img.shields.io/badge/VLESS%2BREALITY-xtls--rprx--vision-2f6df6)

**Русский** · [English](README.en.md)

</div>

---

## Быстрый старт

Под root, на сервере с уже установленной 3x-ui:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ProstyGospody/nx-revpro/main/setup.sh)
```

Спросит два домена, e-mail и предложит первый прогон на тестовом CA. Всё остальное —
сертификаты, конфиги nginx, настройки панели, инбаунд — сделает сам и в конце покажет
`vless://`-ссылку с QR-кодом.

Те же аргументы можно передать сразу:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ProstyGospody/nx-revpro/main/setup.sh) \
  --panel panel.example.com --decoy decoy.example.com --email you@example.com --staging
```

> [!TIP]
> Первый раз запускайте с `--staging`. У Let's Encrypt лимит 5 сертификатов на домен
> в неделю, и на отладке его легко сжечь. Когда проверки прошли — `sudo nxrev install --no-staging`.

## Как это устроено

```
                              ┌─ panel.example.com ──→ 127.0.0.1:7443
                              │                        nginx · панель 3x-ui + подписка
клиент ──→ IP:443 ────────────┤
           nginx stream       │  decoy.example.com ─┐
           ssl_preread        └─ всё остальное ─────┴→ 127.0.0.1:443
                                                       Xray · VLESS+REALITY
                                                          │
                                                          └─ чужое рукопожатие
                                                             ──→ 127.0.0.1:9443
                                                                 nginx · прикрытие + LE-серт
```

Снаружи открыт ровно один порт. `ssl_preread` смотрит SNI, не расшифровывая трафик,
и разводит соединения по трём адресам на loopback.

**Почему nginx слушает конкретный IP, а не `0.0.0.0`.** Иначе он занял бы и `127.0.0.1:443`,
который нужен Xray. А Xray обязан быть именно на 443, потому что 3x-ui берёт порт для
share-ссылки прямо из порта инбаунда — отдельного поля «публичный порт» у неё нет.

**Почему прикрытие настоящее.** Кто пришёл на decoy-домен без валидного VLESS-рукопожатия,
попадает на обычный сайт небольшой конторы с живым сертификатом Let's Encrypt. Скрипт
генерирует его сам: случайные название, ниша, палитра, год основания.

**Где включён PROXY-протокол.** На обоих направлениях от stream-роутера: у панели через
`proxy_protocol` в `listen`, у REALITY через `acceptProxyProtocol` в `tcpSettings`.
Без этого терялся бы реальный IP клиента.

## Перед запуском

| Что | Зачем |
|---|---|
| VPS с Ubuntu 22.04/24.04 или Debian, root | другие дистрибутивы не поддерживаются |
| два домена, оба A-записью на IP сервера | `panel` — панель и подписка, `decoy` — прикрытие и `serverName` для REALITY |
| свободные порты 80 и 443 | скрипт проверит и откажется работать, если заняты |
| установленная 3x-ui | ставится отдельно, см. ниже |

<details>
<summary><b>Установка 3x-ui и что отвечать установщику</b></summary>

<br>

```bash
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
```

| Вопрос | Ответ | Почему |
|---|---|---|
| тип базы данных | **SQLite** | скрипт читает и правит `/etc/x-ui/x-ui.db` напрямую, MySQL не поддерживается |
| настроить SSL сейчас | **Skip** | сертификаты выпустит наш скрипт, TLS терминирует nginx |
| адрес прослушивания | **127.0.0.1** | наружу панель смотрит только через nginx |

Порт и путь панели выбирайте любые — они будут прочитаны из БД, и nginx подстроится.
Логин, пароль и путь установщик кладёт в `/etc/x-ui/install-result.env`.

</details>

## Команды

```bash
sudo nxrev status          # настройки панели, сроки сертификатов, сквозная проверка
sudo nxrev links           # vless://-ссылки и QR для всех клиентов
sudo nxrev regen-decoy     # пересобрать прикрытие с новым названием и нишей
sudo nxrev install --help  # все флаги
```

Обновление — тот же однострочник: код в `/opt/nx-revpro` перезаписывается, конфиг
и состояние в `/etc/nx-revpro` остаются.

### Инбаунд заводится руками

Скрипт его не создаёт и не правит. API 3x-ui меняется от версии к версии — формат
логина, CSRF, тип поля `tgId` — и автосоздание ломалось бы на каждом обновлении
панели. Поэтому инбаунд и клиентов вы заводите в интерфейсе, а скрипт читает их
из БД, сверяет с конфигурацией nginx и собирает `vless://`-ссылки. Нужные
параметры он печатает сам в конце установки.

## Подробности

<details>
<summary><b>Что скрипт меняет в системе</b></summary>

<br>

| Что | Где |
|---|---|
| код и симлинк `nxrev` | `/opt/nx-revpro/`, `/usr/local/bin/nxrev` |
| конфиги nginx | `/etc/nginx/conf.d/nx-revpro-*.conf`, `/etc/nginx/nx-revpro/` |
| блок `stream{}` | дописывается в конец `/etc/nginx/nginx.conf` между маркерами |
| дефолтный сайт Debian | отключается, копия в `/etc/nx-revpro/backup/` |
| сайт-прикрытие и webroot ACME | `/var/www/nx-revpro/` |
| настройки панели | правятся в `/etc/x-ui/x-ui.db`, копия БД перед каждой записью |
| deploy-hook certbot | `/etc/letsencrypt/renewal-hooks/deploy/nx-revpro-reload.sh` |
| конфиг и состояние | `/etc/nx-revpro/nxrev.conf`, `/etc/nx-revpro/state.env` (0600) |

Автопродление сертификатов делает штатный `certbot.timer`, hook только перезагружает nginx.

</details>

<details>
<summary><b>Какие настройки панели переписываются</b></summary>

<br>

| Ключ | Становится | Зачем |
|---|---|---|
| `webCertFile`, `webKeyFile` | пусто | TLS терминирует nginx, панель отдаёт чистый HTTP |
| `webListen` | `127.0.0.1` | снаружи панель напрямую недоступна |
| `webDomain` | пусто | иначе панель включает проверку `Host` и отбивает запросы на `127.0.0.1` |
| `subEnable`, `subListen` | `true`, `127.0.0.1` | подписка ходит через тот же nginx |
| `subURI`, `subJsonURI` | `https://<panel-домен>/…` | чтобы панель выдавала клиентам публичный адрес |

`webPort`, `webBasePath`, `subPath` и `subJsonPath` **не трогаются** — nginx строится под них.

Настройки читаются из БД, а не из `install-result.env`: этот файл устаревает сразу, как
только вы поменяете порт или путь в UI. Учётные данные скрипту вообще не нужны:
в API панели он не ходит и `install-result.env` не читает.

</details>

<details>
<summary><b>Грабли, на которые уже наступили</b></summary>

<br>

- **Порт в share-ссылке** жёстко берётся из порта инбаунда. Отдельного поля нет,
  Custom share address задаёт только адрес. Поэтому инбаунд обязан быть на 443.
- **Custom share address задавать обязательно.** Инбаунд слушает `127.0.0.1`, и без
  явного адреса панель подставляет в ссылку произвольный — вплоть до адреса того,
  кто открыл интерфейс. Впишите туда decoy-домен.
- **`subPath` иногда не сохраняется** и сбрасывается в `/`. Скрипт пишет настройки в БД
  при остановленной панели, а после старта перечитывает и падает с ошибкой, если уехало.
- **Proxy Protocol нужен не всем**: `ON` для REALITY, `OFF` для WS и XHTTP. Если будете
  добавлять такой инбаунд руками, ему нужен отдельный маршрут без `proxy_protocol`.
- **certbot только webroot**, не standalone: nginx уже держит `:80`, останавливать его
  ради продления нельзя.

</details>

<details>
<summary><b>Если что-то не работает</b></summary>

<br>

```bash
sudo nxrev status
sudo nginx -t
sudo ss -lntp | grep -E ':(80|443|7443|9443)'
sudo journalctl -u x-ui -n 50 --no-pager
sudo tail -n 50 /var/log/nginx/nx-revpro-stream.log
```

| Симптом | Обычная причина |
|---|---|
| `127.0.0.1:443` слушает не Xray | nginx забиндился на `0.0.0.0` — проверьте `BIND_IP` в `/etc/nx-revpro/nxrev.conf` |
| REALITY не отдаёт прикрытие | не совпал `serverNames[0]` с decoy-доменом или `dest` смотрит не на `127.0.0.1:9443` |
| панель отвечает 502 | `webListen` не `127.0.0.1` либо `webCertFile` не очищен и панель говорит по TLS |

</details>

## Ограничения

Только Debian/Ubuntu, только SQLite-режим 3x-ui, только IPv4. Единственный транспорт —
VLESS+REALITY поверх TCP с `flow=xtls-rprx-vision`. Удаления скрипт не умеет: снимается
вручную — убрать `nx-revpro-*.conf`, блок между маркерами в `nginx.conf`, `/etc/nx-revpro`
и `/var/www/nx-revpro`.
