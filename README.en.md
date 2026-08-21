<div align="center">

<img src="assets/logo.svg" alt="nx-revpro" width="88">

# nx-revpro

**VLESS + REALITY behind an nginx SNI router.**
Panel, proxy and decoy site all share a single public port 443.

![bash](https://img.shields.io/badge/bash-5.x-2f6df6?logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/Ubuntu%2022.04%20%7C%2024.04%20%7C%20Debian-0e9aa7?logo=ubuntu&logoColor=white)
![3x-ui](https://img.shields.io/badge/3x--ui-v3.6.0-555)
![transport](https://img.shields.io/badge/VLESS%2BREALITY-xtls--rprx--vision-2f6df6)

[Русский](README.md) · **English**

</div>

---

## Quick start

As root, on a server that already has 3x-ui installed:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ProstyGospody/nx-revpro/main/setup.sh)
```

It asks for two domains and an e-mail, then handles the rest — certificates, nginx configs,
panel settings, the inbound — and prints a `vless://` link with a QR code at the end.

You can pass the same arguments up front:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ProstyGospody/nx-revpro/main/setup.sh) \
  --panel panel.example.com --decoy decoy.example.com --email you@example.com --staging
```

> [!TIP]
> Use `--staging` on the first run. Let's Encrypt allows 5 certificates per domain per week
> and that quota is easy to burn while debugging. Once the checks pass, run
> `sudo nxrev install --no-staging`.

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

Exactly one port is open to the world. `ssl_preread` inspects the SNI without decrypting
anything and routes the connection to one of three loopback addresses.

**Why nginx binds a specific IP rather than `0.0.0.0`.** Otherwise it would also take
`127.0.0.1:443`, which Xray needs. And Xray has to sit on 443 specifically, because 3x-ui
builds the share link using the inbound's own port — there is no separate "public port" field.

**Why the decoy is a real site.** Anyone reaching the decoy domain without a valid VLESS
handshake lands on an ordinary small-business website with a genuine Let's Encrypt
certificate. The script generates it: random name, industry, palette and founding year.

**Where PROXY protocol is enabled.** On both legs out of the stream router — `proxy_protocol`
in the panel's `listen`, `acceptProxyProtocol` in the REALITY `tcpSettings`. Without it the
client's real IP would be lost.

## Before you start

| What | Why |
|---|---|
| a VPS running Ubuntu 22.04/24.04 or Debian, root access | other distributions are not supported |
| two domains, both A-records pointing at the server | `panel` for the panel and subscription, `decoy` for the cover site and REALITY `serverName` |
| ports 80 and 443 free | the script checks and refuses to run if they are taken |
| 3x-ui installed | installed separately, see below |

<details>
<summary><b>Installing 3x-ui and what to answer</b></summary>

<br>

```bash
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
```

| Prompt | Answer | Why |
|---|---|---|
| database type | **SQLite** | the script reads and edits `/etc/x-ui/x-ui.db` directly; MySQL is not supported |
| set up SSL now | **Skip** | our script issues the certificates and nginx terminates TLS |
| listen address | **127.0.0.1** | the panel is only reachable through nginx |

Pick any port and path you like — they are read from the database and nginx is built around
them. The installer writes the login, password and path to `/etc/x-ui/install-result.env`.

</details>

## Commands

```bash
sudo nxrev status          # panel settings, certificate expiry, end-to-end check
sudo nxrev links           # vless:// links and QR codes for every client
sudo nxrev add-user alice  # add a client and print its link
sudo nxrev regen-decoy     # rebuild the decoy site with a new name and industry
sudo nxrev install --help  # every flag
```

To update, run the same one-liner: the code in `/opt/nx-revpro` is replaced, while the
config and state in `/etc/nx-revpro` are kept. **The inbound is never touched on re-runs** —
that would regenerate the REALITY keys and break every existing client. The script only
compares it against the current nginx setup and warns if the two have drifted apart.

## Details

<details>
<summary><b>What the script changes on the system</b></summary>

<br>

| What | Where |
|---|---|
| code and the `nxrev` symlink | `/opt/nx-revpro/`, `/usr/local/bin/nxrev` |
| nginx configs | `/etc/nginx/conf.d/nx-revpro-*.conf`, `/etc/nginx/nx-revpro/` |
| the `stream{}` block | appended to `/etc/nginx/nginx.conf` between markers |
| the default Debian site | disabled, backup in `/etc/nx-revpro/backup/` |
| decoy site and ACME webroot | `/var/www/nx-revpro/` |
| panel settings | edited in `/etc/x-ui/x-ui.db`, database backed up before every write |
| certbot deploy hook | `/etc/letsencrypt/renewal-hooks/deploy/nx-revpro-reload.sh` |
| config and state | `/etc/nx-revpro/nxrev.conf`, `/etc/nx-revpro/state.env` (0600) |

Renewal is handled by the stock `certbot.timer`; the hook only reloads nginx.

</details>

<details>
<summary><b>Which panel settings get rewritten</b></summary>

<br>

| Key | Set to | Why |
|---|---|---|
| `webCertFile`, `webKeyFile` | empty | nginx terminates TLS, the panel speaks plain HTTP |
| `webListen` | `127.0.0.1` | the panel is not reachable from outside directly |
| `webDomain` | empty | otherwise the panel enforces a `Host` check and rejects requests to `127.0.0.1` |
| `subEnable`, `subListen` | `true`, `127.0.0.1` | the subscription goes through the same nginx |
| `subURI`, `subJsonURI` | `https://<panel-domain>/…` | so the panel hands clients a public address |

`webPort`, `webBasePath`, `subPath` and `subJsonPath` are **left alone** — nginx is built around them.

Settings are read from the database rather than `install-result.env`, which goes stale the
moment you change the port or path in the UI. Only the API token or login is taken from it.

</details>

<details>
<summary><b>Traps we already walked into</b></summary>

<br>

- **The port in a share link** comes straight from the inbound's port. There is no separate
  field, and Custom share address only sets the address. Hence the inbound must live on 443.
- **`subPath` sometimes fails to save** and resets to `/`. The script writes settings with the
  panel stopped, then reads them back after start-up and fails loudly if anything drifted.
- **Proxy Protocol is not universal**: `ON` for REALITY, `OFF` for WS and XHTTP. If you add
  such an inbound by hand, it needs its own route without `proxy_protocol`.
- **certbot via webroot only**, never standalone: nginx already holds `:80` and stopping it
  for a renewal is not an option.

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
| `127.0.0.1:443` is not Xray | nginx bound `0.0.0.0` — check `BIND_IP` in `/etc/nx-revpro/nxrev.conf` |
| REALITY never serves the decoy | `serverNames[0]` does not match the decoy domain, or `dest` is not `127.0.0.1:9443` |
| the panel returns 502 | `webListen` is not `127.0.0.1`, or `webCertFile` was not cleared and the panel is speaking TLS |

</details>

## Limitations

Debian/Ubuntu only, SQLite-mode 3x-ui only, IPv4 only. The single supported transport is
VLESS+REALITY over TCP with `flow=xtls-rprx-vision`. There is no uninstall command: remove
`nx-revpro-*.conf`, the marked block in `nginx.conf`, `/etc/nx-revpro` and `/var/www/nx-revpro`
by hand.
