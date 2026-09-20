#!/usr/bin/env bash
# English message catalogue. Keys match lang/ru.sh — tests/check_lang.sh
# keeps the two sets in sync.
# shellcheck shell=bash disable=SC2034

M[tagline]="VLESS+REALITY behind an nginx SNI router"

# --- environment -------------------------------------------------------------
M[need_root]="root privileges required: sudo %s"
M[os_bad]="only Debian and Ubuntu are supported (found: %s)"
M[os_ok]="OS: %s"
M[no_osrelease]="/etc/os-release not found — only Debian and Ubuntu are supported"
M[pkg_install]="installing packages: %s"
M[pkg_fail]="apt-get could not install: %s"
M[pkg_ok]="dependencies are in place"
M[nginx_nostream]="this nginx has no ssl_preread — install nginx-full or libnginx-mod-stream"
M[nginx_nomod]="/etc/nginx/modules-enabled/50-mod-stream.conf is missing; if stream fails to load, check libnginx-mod-stream"
M[nginx_stream_ok]="stream and ssl_preread are available"
M[nginx_ver]="nginx %s"
M[xui_nodb]="panel database %s not found — install 3x-ui first (see README)"
M[xui_nounit]="no systemd unit %s.service"
M[xui_notsqlite]="%s does not look like SQLite — MySQL mode is not supported"
M[xui_ok]="3x-ui found, SQLite database"

# --- network -------------------------------------------------------------------
M[bind_unknown]="could not determine the bind IP — pass --bind-ip"
M[pub_unknown]="could not determine the public IP, assuming %s"
M[nat_detected]="public IP %s, local %s — looks like NAT, binding the local one"
M[addr_ok]="bind %s:443, reachable at %s:%s"
M[dns_missing]="%s: no A record. Point the domain at %s or run with --force"
M[dns_missing_force]="%s: no A record found (--force)"
M[dns_wrong]="%s points at %s, not %s. Fix DNS or use --force"
M[dns_wrong_force]="%s -> %s while the server is %s (--force)"
M[dns_ok]="%s -> %s"
M[port_reuse]="%s:%s already belongs to nginx.service — reusing"
M[port_foreign_nginx]="%s:%s is held by an nginx outside nginx.service (pid %s)"
M[port_foreign_cmd]="command: %s"
M[port_foreign_why]="that process never read our configs: requests get 404 and nginx.service cannot take the port"
M[port_busy]="%s:%s is taken by another process: %s"
M[port_xray]="127.0.0.1:443 is held by something other than Xray: %s"
M[ports_ok]="ports are available (:80, %s:443, 127.0.0.1:%s, 127.0.0.1:%s)"

# --- panel ----------------------------------------------------------------------
M[panel_db_backup]="database backup: %s"
M[panel_stop_fail]="could not stop %s"
M[panel_start_fail]="could not start %s"
M[panel_down]="the panel did not come up on 127.0.0.1:%s"
M[panel_odd_code]="the panel root answers %s — it is already refusing, before any settings check"
M[panel_weblisten_bad]="webListen was not saved: '%s'"
M[panel_cert_bad]="webCertFile and webKeyFile were not cleared"
M[panel_domain_bad]="webDomain was not cleared: '%s' — the panel will reject 127.0.0.1 with 403"
M[panel_subpath_moved]="subPath drifted: '%s' -> '%s'"
M[panel_basepath_moved]="webBasePath drifted: '%s' -> '%s'"
M[panel_apply_fail]="panel settings were not applied; the original database is at %s"
M[panel_applied]="panel: http://127.0.0.1:%s%s (TLS removed, listening on loopback)"
M[panel_sub_applied]="subscription: 127.0.0.1:%s%s"
M[sqlite_read_fail]="sqlite3: could not read settings.%s"
M[sqlite_write_fail]="sqlite3: could not write settings.%s"

# --- certificates ------------------------------------------------------------------
M[cert_hook]="deploy hook: %s"
M[cert_timer_ok]="auto-renewal: %s is active"
M[cert_timer_off]="the certbot timer is not enabled — systemctl enable --now certbot.timer"
M[cert_skip]="certificate %s: %s days left, no reissue needed"
M[cert_switch]="certificate %s changes type (staging=%s -> %s), reissuing"
M[cert_request]="certbot: %s (staging=%s)"
M[cert_retry_delete]="could not reissue over the staging one — deleting it and retrying"
M[cert_fail]="certbot did not issue a certificate for %s — see /var/log/letsencrypt/letsencrypt.log"
M[cert_missing_after]="certbot finished but %s did not appear"
M[cert_still_staging]="%s still has a staging certificate — browsers will not trust it"
M[cert_ready]="certificate %s is ready (%s days left)"
M[cert_none]="%s: no certificate"
M[cert_days]="%s: %s days%s"
M[staging_warn]="--staging mode: certificates are untrusted, for debugging only"
M[webroot_ok]="the webroot for %s is served correctly"
M[webroot_fail]="webroot check for %s failed: HTTP %s"
M[webroot_why]="that path returns someone else's file — another server block is handling it"
M[webroot_errlog]="last nginx errors:"
M[webroot_perms]="permissions along the webroot path:"
M[acme_blocked]="the ACME challenge will not arrive — no certificate can be issued"

# --- nginx --------------------------------------------------------------------------
M[nginx_default_off]="disabled /etc/nginx/sites-enabled/default (backup: %s)"
M[nginx_main_patched]="stream{} added to nginx.conf (backup: %s)"
M[nginx_main_ok]="nginx.conf already includes the stream router"
M[nginx_stream_exists]="%s already has a stream{} block. Add inside it: include %s/*.conf;"
M[nginx_wrote]="%s"
M[nginx_test_fail]="nginx -t failed"
M[nginx_test_ok]="nginx configuration is valid"
M[nginx_start_fail]="nginx does not start"
M[nginx_inactive]="nginx.service is not active after the restart"
M[nginx_restarted]="nginx restarted with the new configuration"
M[nginx_notloaded]="nginx.conf does not include %s/*.conf — our blocks do not exist for nginx"
M[nginx_files_ok]="nx-revpro configs are in place and syntactically valid"
M[nginx_notbound]="%s:%s is not bound yet"
M[nginx_rebind]="nginx did not take the expected addresses — a reload does not rebind them, restarting"
M[nginx_bound_ok]="nginx is listening on every expected address"
M[nginx_bind_fail]="nginx did not take the required addresses"
M[nginx_errlog]="last lines of error.log:"

# --- decoy ---------------------------------------------------------------------------
M[decoy_kept]="decoy site already in place: %s [%s]"
M[decoy_made]="decoy site generated: %s [%s], established %s"

# --- inbound -------------------------------------------------------------------------
M[inb_missing]="inbound not found — create it in the panel, parameters below"
M[inb_port_taken]="no inbound named '%s', but port %s is taken by inbound '%s'"
M[inb_ok]="inbound '%s' matches the nginx configuration"
M[inb_broken]="the inbound does not match the nginx configuration — fix it in the panel"
M[inb_proto]="protocol '%s', expected vless"
M[inb_port]="inbound port %s while %s is exposed — the share link is built from the inbound port"
M[inb_listen]="the inbound listens on '%s', expected 127.0.0.1"
M[inb_pp]="Proxy Protocol is off while the stream router sends it — connections will not establish"
M[inb_sec]="security '%s', expected reality"
M[inb_dest]="realitySettings.dest '%s', expected 127.0.0.1:%s"
M[inb_sni]="serverNames[0] '%s' while the certificate is issued for %s"
M[inb_flow]="%s client(s) do not use flow xtls-rprx-vision"
M[inb_share_unset]="Custom share address is empty — links copied from the panel will carry the wrong address"
M[inb_share_hint]="set it in the inbound to: %s"
M[inb_share_wrong]="Custom share address '%s', expected %s"
M[inb_nopbk]="the inbound has no publicKey — cannot build a link"
M[inb_noclients]="the inbound has no clients — add them in the panel"
M[inb_title]="Create the inbound in the panel"
M[inb_panel_at]="Panel: https://%s%s"
M[inb_notes]="Two fields are easy to miss and nothing works without them:"
M[inb_note_pp]="Proxy Protocol — the stream router sends a PROXY header; without it Xray drops the connection"
M[inb_note_share]="Custom share address — the inbound sits on 127.0.0.1, so the panel will guess an address for the link"
M[inb_note_keys]="The panel generates REALITY keys with Get New Cert. Client flow is xtls-rprx-vision."

# --- install steps ---------------------------------------------------------------------
M[step_env]="Environment check"
M[step_net]="Network and DNS"
M[step_panel_read]="Current panel settings"
M[step_panel_apply]="Adjusting the panel for nginx"
M[step_decoy]="Decoy site"
M[step_acme]="nginx: certificate issuance profile"
M[step_certs]="Let's Encrypt certificates"
M[step_full]="nginx: SNI router"
M[step_inbound]="VLESS+REALITY inbound"
M[step_verify]="Verification"

# --- verification ------------------------------------------------------------------------
M[v_listen_ok]="listening on %s:%s (%s)"
M[v_listen_no]="nothing is listening on %s:%s (%s)"
M[v_listen_skip]="127.0.0.1:%s is free — no inbound yet, which is expected"
M[v_panel_ok]="the panel answers 200 through the SNI router"
M[v_panel_no]="the panel at https://%s%s returned %s"
M[v_decoy_direct_ok]="the decoy site answers directly on 127.0.0.1:%s"
M[v_decoy_direct_no]="the decoy site on 127.0.0.1:%s returned %s — that is nginx, not REALITY"
M[v_reality_skip]="skipping the REALITY check: no inbound yet"
M[v_reality_ok]="the decoy site answers 200 through the REALITY fallback"
M[v_reality_no]="https://%s/ returned %s — REALITY did not hand the connection to :%s"
M[v_reality_hint]="common cause: Proxy Protocol is off on the inbound"
M[v_cert_skip]="skipping the decoy-SNI certificate check: the connection goes through REALITY"
M[v_cert_ok]="the decoy SNI serves a certificate: %s"
M[v_cert_no]="the decoy SNI served an unexpected certificate: %s"
M[v_partial]="some checks did not pass — see the output above"

# --- summary -------------------------------------------------------------------------------
M[sum_title]="Done"
M[sum_panel]="Panel"
M[sum_sub]="Subscription"
M[sum_decoy]="Decoy"
M[sum_conf]="Config"
M[sum_state]="State"
M[sum_links]="Links"
M[sum_staging]="Certificates are staging. Re-run with --no-staging for real ones."
M[sum_addmore]="Add new clients in the panel, then run: nxrev links"

# --- rollback and removal --------------------------------------------------------------------
M[rollback_doing]="installation interrupted — restoring panel settings from the backup"
M[rollback_done]="panel settings restored from %s"
M[rollback_fail]="could not restore the panel database; the backup is at %s"
M[rollback_none]="panel settings were never changed, nothing to roll back"
M[uninstall_confirm]="This removes the nginx configs, the decoy site and nx-revpro settings. Continue? [y/N]: "
M[uninstall_abort]="cancelled"
M[uninstall_nginx]="nginx configs removed"
M[uninstall_stream]="stream{} block removed from nginx.conf"
M[uninstall_web]="removed %s"
M[uninstall_panel]="panel settings restored from %s"
M[uninstall_panel_skip]="no panel database backup — its settings are left as they are"
M[uninstall_default]="/etc/nginx/sites-enabled/default restored"
M[uninstall_certs]="Let's Encrypt certificates kept: certbot delete --cert-name %s"
M[uninstall_done]="nx-revpro removed. The panel inbound was left untouched."

# --- misc ---------------------------------------------------------------------------------
M[cmd_unknown]="unknown command: %s"
M[arg_unknown]="unknown argument: %s (--help)"
M[arg_noval]="%s requires a value"
M[need_panel]="--panel is missing"
M[need_decoy]="--decoy is missing"
M[same_domains]="--panel and --decoy must differ"
M[not_installed]="%s not found — run install --panel ... --decoy ... first"
M[inb_notfound]="inbound '%s' not found"

M[val_empty]="<empty>"
M[val_all_ifaces]="<all interfaces>"

M[usage]="  nxrev install --panel <domain> --decoy <domain> [--email <address>] [options]
  nxrev status          check the panel, the certificates and the whole chain
  nxrev links           vless:// links and QR codes for the inbound clients
  nxrev regen-decoy     rebuild the decoy site
  nxrev uninstall       remove nx-revpro and restore the previous state

Install options:
  --panel   <domain>    panel and subscription domain
  --decoy   <domain>    decoy domain, also the REALITY serverName
  --email   <address>   contact address for Let's Encrypt
  --bind-ip <ip>        public IP for nginx (default: from the routing table)
  --share-address <host> address used in share links (default: the decoy domain)
  --remark  <string>    inbound name to look for (default: nx-reality)
  --staging             Let's Encrypt staging CA, spends no production quota
  --no-staging          switch back to the production CA after debugging
  --regen-decoy         rebuild the decoy site from scratch
  --force               do not stop when DNS has not propagated yet
  --lang    ru|en       message language, remembered in the config
  --apt-wait <seconds>  how long to wait for a foreign apt when the lock is not
                        held by automatic updates (default 120)
  -y, --yes             skip the confirmation prompt (for uninstall)
  -h, --help            this help

The inbound is created by hand in the panel: the 3x-ui API shifts between
releases. The script finds it, checks it against nginx and prints the links."

M[apt_waiting]="waited %s s; on a fresh system unattended-upgrades holds it for minutes"
M[apt_lock_free]="the lock was released after %s s"
M[pkg_fail_hint]="if automatic updates are in the way: systemctl status unattended-upgrades"

M[apt_unit_stopped]="stopped %s"
M[apt_foreign_holder]="the lock is held by %s (pid %s) — not automatic updates, waiting instead of killing"
M[apt_repair]="repairing dpkg after the interrupted upgrade"
M[apt_timers_restored]="automatic update timers restored"

M[apt_disarmed]="automatic updates stopped, waiting for the lock to clear"
