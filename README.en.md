<div align="center">

<img src="assets/logo.svg" alt="nx-revpro" width="88">

# nx-revpro

**VLESS + REALITY behind an nginx SNI router.**
Panel, proxy and decoy site share a single public port 443.

![bash](https://img.shields.io/badge/bash-5.x-2f6df6?logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/Ubuntu%2022.04%20%7C%2024.04%20%7C%20Debian-0e9aa7?logo=ubuntu&logoColor=white)
![3x-ui](https://img.shields.io/badge/3x--ui-3.8.x-555)
[![ci](https://github.com/ProstyGospody/nx-revpro/actions/workflows/ci.yml/badge.svg)](https://github.com/ProstyGospody/nx-revpro/actions/workflows/ci.yml)

[Русский](README.md) · **English**

</div>

---

## Quick start

As root, on a server that already runs 3x-ui:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ProstyGospody/nx-revpro/main/setup.sh)
```

It asks for a language, two domains and the CA mode, then handles the rest: certificates,
nginx configs, panel settings, the decoy site — and prints what to create in the panel.

> [!TIP]
> Use the staging CA on the first run (offered by default). Let's Encrypt allows 5
> certificates per domain per week. Once the checks pass: `sudo nxrev install --no-staging`.

## How it works

```
                              ┌─ panel.example.com ──→ 127.0.0.1:7443
                              │                        nginx · 3x-ui panel + subscription
client ──→ IP:443 ────────────┤
           nginx stream       │  decoy.example.com ─┐
           ssl_preread        └─ everything else ───┴→ 127.0.0.1:443
                                                       Xray · VLESS+REALITY
                                                          │
                                                          └─ unrecognised handshake
                                                             ──→ 127.0.0.1:9443
                                                                 nginx · decoy site + LE cert
```

One port is open to the world. `ssl_preread` inspects the SNI without decrypting anything
and routes the connection to one of three loopback addresses.

**nginx binds a specific IP rather than `0.0.0.0`** — otherwise it would also take
`127.0.0.1:443`, which Xray needs. And Xray must sit on 443, because 3x-ui builds the share
link from the inbound's own port.

**The decoy is a real site.** Anyone reaching the decoy domain without a valid VLESS
handshake lands on an ordinary small-business website with a genuine certificate. The script
generates it: random name, industry, palette and founding year.

**PROXY protocol is on** for both legs out of the stream router: `proxy_protocol` in the
panel's `listen`, `acceptProxyProtocol` in the REALITY inbound.

## Requirements

Ubuntu 22.04/24.04 or Debian, root access. Two domains with A-records pointing at the
server. Ports 80 and 443 free. 3x-ui installed in SQLite mode.

<details>
<summary><b>Installing 3x-ui and what to answer</b></summary>

<br>

```bash
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
```

| Prompt | Answer | Why |
|---|---|---|
| database type | **SQLite** | the script reads `/etc/x-ui/x-ui.db` directly |
| set up SSL | **Skip** | our script issues the certificates, nginx terminates TLS |
| listen address | **127.0.0.1** | the panel is only reachable through nginx |

Pick any port and path — the script reads them from the database and builds nginx around them.

</details>

## Commands

```bash
sudo nxrev status        # panel, certificates, inbound, end-to-end check
sudo nxrev links         # vless:// links and QR codes
sudo nxrev regen-decoy   # rebuild the decoy site
sudo nxrev uninstall     # remove everything and restore the previous state
sudo nxrev install --help
```

Language is switched with `--lang ru|en` and remembered in the config.

## The inbound is created by hand

The script neither creates nor edits it. The 3x-ui API shifts between releases — login
format, CSRF, the type of `tgId` — so automatic creation would break on every panel upgrade.
You create the inbound in the UI; the script reads it from the database, checks it against
nginx and builds the links. It prints the exact parameters at the end of the install. Two
fields are easy to miss:

- **Proxy Protocol — on.** The stream router sends a PROXY header; without it Xray treats
  it as garbage and drops the connection.
- **Custom share address — the decoy domain.** The inbound listens on `127.0.0.1`, so
  without an explicit address the panel puts an arbitrary one into the link.

<details>
<summary><b>What changes on the system</b></summary>

<br>

| What | Where |
|---|---|
| code and the `nxrev` symlink | `/opt/nx-revpro/`, `/usr/local/bin/nxrev` |
| nginx configs | `/etc/nginx/conf.d/nx-revpro-*.conf`, `/etc/nginx/nx-revpro/` |
| the `stream{}` block | appended to `nginx.conf` between markers |
| the default Debian site | disabled, backup in `/etc/nx-revpro/backup/` |
| decoy site and ACME webroot | `/var/www/nx-revpro/` |
| panel settings | edited in `/etc/x-ui/x-ui.db`, backed up before every write |
| certbot deploy hook | `/etc/letsencrypt/renewal-hooks/deploy/nx-revpro-reload.sh` |
| config and state | `/etc/nx-revpro/` (0600) |

`uninstall` restores all of it from those same backups. Certificates and the inbound are
left alone.

Panel settings: `webCertFile`, `webKeyFile` and `webDomain` are cleared; `webListen` and
`subListen` become `127.0.0.1`; the subscription is enabled. `webPort`, `webBasePath` and
`subPath` are **left alone** — nginx is built around them. The script needs no credentials:
it never calls the panel API.

</details>

<details>
<summary><b>Traps we already walked into</b></summary>

<br>

- **The share-link port** comes from the inbound's port; there is no separate field. Hence 443.
- **Custom share address is mandatory** — see above.
- **`subPath` sometimes resets to `/`.** The script writes settings with the panel stopped
  and verifies the result after start-up.
- **Proxy Protocol is not universal**: `ON` for REALITY, `OFF` for WS and XHTTP.
- **certbot via webroot only.** nginx already holds `:80` and must not be stopped.
- **A fresh VPS is busy with automatic updates.** For the first minutes after boot
  `unattended-upgrades` holds the dpkg lock and `apt-get` fails. The script waits for
  it, naming the holder and reporting how long it has waited.
- **`nginx -s reload` does not rebind sockets** and returns 0 even when a new `listen`
  failed to bind. That is why configs are applied with a restart.

</details>

<details>
<summary><b>When something breaks</b></summary>

<br>

```bash
sudo nxrev status
sudo nginx -t
sudo ss -lntp | grep -E ':(80|443|7443|9443)'
sudo journalctl -u x-ui -n 50 --no-pager
sudo tail -n 50 /var/log/nginx/nx-revpro-stream.log
```

| Symptom | Usual cause |
|---|---|
| `127.0.0.1:443` is empty | no inbound, or it sits on another port |
| REALITY never serves the decoy | Proxy Protocol is off, or `dest`/`serverNames` are wrong |
| the panel returns 502 | `webListen` is not `127.0.0.1`, or `webCertFile` was not cleared |
| browser says "not secure" | the certificates are staging, run `--no-staging` |

</details>

## Development

```bash
bash tests/unit.sh        # pure functions
bash tests/check_lang.sh  # ru/en catalogue parity
bash tests/decoy.sh       # decoy site generator
shellcheck nxrev.sh setup.sh lib/*.sh lang/*.sh tests/*.sh
```

CI runs the same on every push.

## Limitations

Debian/Ubuntu only, SQLite-mode 3x-ui only, IPv4 only. The single supported transport is
VLESS+REALITY over TCP with `flow=xtls-rprx-vision`.
