<div align="center">

<img src="assets/logo.svg" alt="nx-revpro" width="88">

# nx-revpro

**VLESS + REALITY за nginx SNI-роутером.**
Панель, прокси и сайт-прикрытие делят один публичный порт 443.

![bash](https://img.shields.io/badge/bash-5.x-2f6df6?logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/Ubuntu%2022.04%20%7C%2024.04%20%7C%20Debian-0e9aa7?logo=ubuntu&logoColor=white)
![3x-ui](https://img.shields.io/badge/3x--ui-3.8.x-555)
[![ci](https://github.com/ProstyGospody/nx-revpro/actions/workflows/ci.yml/badge.svg)](https://github.com/ProstyGospody/nx-revpro/actions/workflows/ci.yml)

**Русский** · [English](README.en.md)

</div>

---

## Быстрый старт

Под root, на сервере с уже установленной 3x-ui:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ProstyGospody/nx-revpro/main/setup.sh)
```

Спросит язык, два домена и режим CA. Дальше сделает всё сам: сертификаты, конфиги
nginx, настройки панели, сайт-прикрытие — и покажет, что завести в панели.

> [!TIP]
> Первый прогон — с тестовым CA (предлагается по умолчанию). У Let's Encrypt лимит
> 5 сертификатов на домен в неделю. Когда проверки прошли: `sudo nxrev install --no-staging`.

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

Снаружи открыт один порт. `ssl_preread` смотрит SNI, не расшифровывая трафик, и разводит
соединения по трём адресам на loopback.

**nginx слушает конкретный IP, а не `0.0.0.0`** — иначе занял бы и `127.0.0.1:443`, нужный
Xray. А Xray обязан быть на 443, потому что 3x-ui берёт порт для share-ссылки прямо из
порта инбаунда.

**Прикрытие настоящее.** Кто пришёл на decoy-домен без валидного VLESS-рукопожатия,
попадает на обычный сайт небольшой конторы с живым сертификатом. Скрипт генерирует его
сам: случайные название, ниша, палитра, год основания.

**PROXY-протокол включён** на обоих направлениях от stream-роутера: у панели через
`proxy_protocol` в `listen`, у REALITY через `acceptProxyProtocol`.

## Требования

Ubuntu 22.04/24.04 или Debian, root. Два домена A-записями на IP сервера. Свободные
порты 80 и 443. Установленная 3x-ui в режиме SQLite.

<details>
<summary><b>Установка 3x-ui и что отвечать</b></summary>

<br>

```bash
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
```

| Вопрос | Ответ | Почему |
|---|---|---|
| тип базы данных | **SQLite** | скрипт читает `/etc/x-ui/x-ui.db` напрямую |
| настроить SSL | **Skip** | сертификаты выпустит наш скрипт, TLS терминирует nginx |
| адрес прослушивания | **127.0.0.1** | наружу панель смотрит только через nginx |

Порт и путь панели — любые, скрипт прочитает их из БД и подстроит nginx.

</details>

## Команды

```bash
sudo nxrev status        # панель, сертификаты, инбаунд, сквозная проверка
sudo nxrev links         # vless://-ссылки и QR
sudo nxrev regen-decoy   # пересобрать прикрытие
sudo nxrev uninstall     # снять всё и вернуть систему как было
sudo nxrev install --help
```

Язык переключается `--lang ru|en` и запоминается в конфиге.

## Инбаунд заводится руками

Скрипт его не создаёт и не правит. API 3x-ui меняется от версии к версии — формат логина,
CSRF, тип поля `tgId` — и автосоздание ломалось бы на каждом обновлении панели. Вы заводите
инбаунд в интерфейсе, а скрипт читает его из БД, сверяет с nginx и собирает ссылки.
Нужные параметры он печатает в конце установки; два поля легко пропустить:

- **Proxy Protocol — включить.** Stream-роутер шлёт PROXY-заголовок, без этого Xray
  примет его за мусор и оборвёт соединение.
- **Custom share address — decoy-домен.** Инбаунд слушает `127.0.0.1`, и без явного
  адреса панель подставит в ссылку произвольный.

<details>
<summary><b>Что меняется в системе</b></summary>

<br>

| Что | Где |
|---|---|
| код и симлинк `nxrev` | `/opt/nx-revpro/`, `/usr/local/bin/nxrev` |
| конфиги nginx | `/etc/nginx/conf.d/nx-revpro-*.conf`, `/etc/nginx/nx-revpro/` |
| блок `stream{}` | дописывается в конец `nginx.conf` между маркерами |
| дефолтный сайт Debian | отключается, копия в `/etc/nx-revpro/backup/` |
| прикрытие и webroot ACME | `/var/www/nx-revpro/` |
| настройки панели | правятся в `/etc/x-ui/x-ui.db`, копия перед каждой записью |
| deploy-hook certbot | `/etc/letsencrypt/renewal-hooks/deploy/nx-revpro-reload.sh` |
| конфиг и состояние | `/etc/nx-revpro/` (0600) |

`uninstall` возвращает всё это обратно из тех же копий. Сертификаты и инбаунд не трогает.

Настройки панели: очищаются `webCertFile`, `webKeyFile`, `webDomain`; `webListen` и
`subListen` становятся `127.0.0.1`; включается подписка. `webPort`, `webBasePath`, `subPath`
**не трогаются** — nginx строится под них. Учётные данные скрипту не нужны: в API он не ходит.

</details>

<details>
<summary><b>Грабли, на которые уже наступили</b></summary>

<br>

- **Порт в share-ссылке** берётся из порта инбаунда, отдельного поля нет. Отсюда 443.
- **Custom share address обязателен** — см. выше.
- **`subPath` иногда сбрасывается в `/`.** Скрипт пишет настройки при остановленной
  панели и после старта сверяет результат.
- **Proxy Protocol нужен не всем**: `ON` для REALITY, `OFF` для WS и XHTTP.
- **certbot только webroot.** nginx уже держит `:80`, останавливать его нельзя.
- **Свежий VPS занят автообновлением.** Первые минуты после старта
  `unattended-upgrades` держит блокировку dpkg, и `apt-get` падает. Скрипт не ждёт:
  сразу штатно останавливает автообновление и чинит dpkg через `dpkg --configure -a`.
  Ни `kill -9`, ни удаления файлов блокировки: прерванная посреди транзакции dpkg
  оставляет базу пакетов недоразобранной. Чужой `apt`, запущенный человеком,
  не трогается — только автообновление. Время ожидания меняется `--apt-wait`.
- **`nginx -s reload` не перепривязывает сокеты** и возвращает 0, даже если новый
  `listen` не смог забиндиться. Поэтому конфиги применяются перезапуском.

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
| `127.0.0.1:443` пуст | инбаунда нет либо он на другом порту |
| REALITY не отдаёт прикрытие | выключен Proxy Protocol, либо `dest`/`serverNames` не те |
| панель отвечает 502 | `webListen` не `127.0.0.1` или `webCertFile` не очищен |
| браузер: «не защищено» | сертификаты тестовые, нужен `--no-staging` |

</details>

## Разработка

```bash
bash tests/unit.sh        # чистые функции
bash tests/check_lang.sh  # согласованность каталогов ru/en
bash tests/decoy.sh       # генератор прикрытия
shellcheck nxrev.sh setup.sh lib/*.sh lang/*.sh tests/*.sh
```

То же самое гоняет CI на каждый push.

## Ограничения

Только Debian/Ubuntu, только SQLite-режим 3x-ui, только IPv4. Единственный транспорт —
VLESS+REALITY поверх TCP с `flow=xtls-rprx-vision`.
