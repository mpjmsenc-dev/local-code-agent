#!/usr/bin/env bash
# netmode.sh — internet kill switch (offline|online|status) + always-on
# inbound guard.
#
# offline: nftables egress lockdown — every NEW outbound connection on the
#          WAN side is dropped, EXCEPT loopback and the Tailscale path
#          (tailscale0 interface, tailscaled's fwmark-tagged control/data
#          traffic, WireGuard/STUN ports, plus DNS so tailscaled can find
#          its coordination server). Both locally-generated (output) and
#          forwarded/masqueraded (docker-bridge container) traffic obey it.
#          Your phone keeps reaching Open WebUI and SSH over Tailscale;
#          Ollama, WebUI, aider, apt and everything else have ZERO internet.
#          Inference is unaffected — models are local.
# online:  restore normal egress.
# status:  print the persisted mode AND prove it with a live probe.
# harden:  (re)apply the always-on INBOUND guard (see below).
#
# Inbound guard (always on, independent of offline/online): a second nft
# table drops NEW inbound connections to the Open WebUI and Ollama ports on
# every interface EXCEPT loopback and tailscale0. Those services bind all
# interfaces (Open WebUI uses docker --network=host), so without this guard
# a droplet's public IP would expose them; the guard makes the private-only
# guarantee real without touching SSH (port 22) or any other port, so it can
# never lock you out. It is applied at setup, whenever WebUI is (re)created,
# and re-applied on every boot.
#
# The mode persists across reboots (ruleset + state file in
# /etc/local-code-agent, re-applied by a systemd oneshot).
#
# Honest caveat: the encrypted Tailscale tunnel still uses the network as
# transport — "offline" means the AI stack cannot reach the internet, not
# that the NIC is dead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
# No load_env here on purpose: render-* must keep stdout to pure nft syntax,
# and running under sudo must not create a root-owned .env as a side effect.
# The inbound guard reads WEBUI_PORT / OLLAMA_HOST directly from .env if it
# exists (see *_from_env below) without creating it.

NFT_TABLE="lca_netmode"
NFT_RULES_FILE="${NETMODE_DIR}/netmode.nft"
INBOUND_TABLE="lca_inbound"
INBOUND_RULES_FILE="${NETMODE_DIR}/inbound.nft"
NETMODE_SERVICE=/etc/systemd/system/local-code-agent-netmode.service

# render_rules — print the OFFLINE ruleset to stdout. Kept separate from
# write_rules_file so tests can validate it (nft --check) without root
# writes or touching the live ruleset.
render_rules() {
  # The create-then-delete preamble makes 'nft -f' idempotent: it works
  # whether or not the table already exists.
  {
    echo "#!/usr/sbin/nft -f"
    echo "# local-code-agent netmode OFFLINE ruleset (managed by netmode.sh)"
    echo "table inet ${NFT_TABLE}"
    echo "delete table inet ${NFT_TABLE}"
    echo "table inet ${NFT_TABLE} {"
    echo "  chain egress {"
    echo "    type filter hook output priority 0; policy accept;"
    echo ""
    echo "    # Local traffic is always fine (Ollama, WebUI, SSH replies)."
    echo "    oifname \"lo\" accept"
    echo ""
    echo "    # The Tailscale path must NEVER be cut — this is how the phone"
    echo "    # reaches WebUI/SSH, and how you toggle back online remotely."
    echo "    oifname \"tailscale0\" accept"
    echo "    # tailscaled marks its own control/data packets with fwmark"
    echo "    # 0x80000 (mask 0xff0000) so they bypass tailscale routing."
    echo "    meta mark & 0x00ff0000 == 0x00080000 accept"
    echo "    # WireGuard data + STUN NAT traversal, both directions."
    echo "    udp dport 41641 accept"
    echo "    udp sport 41641 accept"
    echo "    udp dport 3478 accept"
    echo ""
    echo "    # Keep the host's plumbing alive: DNS (tailscaled needs to"
    echo "    # resolve its coordination server), DHCP lease renewal, and"
    echo "    # IPv6 neighbor discovery."
    echo "    udp dport 53 accept"
    echo "    tcp dport 53 accept"
    echo "    udp dport { 67, 68, 547 } accept"
    echo "    icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit } accept"
    echo ""
    echo "    # Replies to connections that already exist keep flowing."
    echo "    ct state established,related accept"
    echo ""
    echo "    # Everything else that tries to START an outbound connection"
    echo "    # is dropped: apt, curl, docker pulls, telemetry — all of it."
    echo "    ct state new counter drop"
    echo "  }"
    echo ""
    echo "  # The output hook only sees locally-generated packets. Traffic"
    echo "  # from docker-bridge containers is routed+masqueraded and crosses"
    echo "  # the FORWARD hook instead, so mirror the egress logic here or"
    echo "  # containers would keep full internet while 'offline'."
    echo "  chain forward {"
    echo "    type filter hook forward priority 0; policy accept;"
    echo "    oifname \"tailscale0\" accept"
    echo "    ct state established,related accept"
    echo "    ct state new counter drop"
    echo "  }"
    echo "}"
  }
}

write_rules_file() {
  as_root mkdir -p "${NETMODE_DIR}"
  render_rules | as_root tee "${NFT_RULES_FILE}" >/dev/null
}

# --- Always-on inbound guard -----------------------------------------------

# webui_port_from_env / ollama_port_from_env — read the ports the guard must
# protect straight from .env (without creating it). Values are validated to
# be numeric so a malformed .env can never inject into the ruleset.
webui_port_from_env() {
  local port=""
  [[ -f "${ENV_FILE}" ]] && port="$(sed -n 's/^WEBUI_PORT=//p' "${ENV_FILE}" | tail -1)"
  [[ "${port}" =~ ^[0-9]+$ ]] || port=3000
  printf '%s\n' "${port}"
}
ollama_port_from_env() {
  local host="" port=""
  [[ -f "${ENV_FILE}" ]] && host="$(sed -n 's/^OLLAMA_HOST=//p' "${ENV_FILE}" | tail -1)"
  case "${host}" in
    *:*) port="${host##*:}" ;;
  esac
  [[ "${port}" =~ ^[0-9]+$ ]] || port=11434
  printf '%s\n' "${port}"
}

# render_inbound_rules — print the always-on inbound guard to stdout. Drops
# NEW inbound to the WebUI/Ollama ports on every interface except loopback
# and tailscale0. SSH (22) and all other ports are left fully open, so this
# guard cannot lock anyone out.
render_inbound_rules() {
  local webui_port ollama_port
  webui_port="$(webui_port_from_env)"
  ollama_port="$(ollama_port_from_env)"
  {
    echo "#!/usr/sbin/nft -f"
    echo "# local-code-agent inbound guard (managed by netmode.sh) — ALWAYS on,"
    echo "# independent of the offline/online egress toggle."
    echo "table inet ${INBOUND_TABLE}"
    echo "delete table inet ${INBOUND_TABLE}"
    echo "table inet ${INBOUND_TABLE} {"
    echo "  chain ingress {"
    echo "    type filter hook input priority 0; policy accept;"
    echo ""
    echo "    # Loopback and the Tailscale path are always allowed: local"
    echo "    # health checks use lo, and the phone reaches WebUI/SSH over"
    echo "    # tailscale0."
    echo "    iifname \"lo\" accept"
    echo "    iifname \"tailscale0\" accept"
    echo "    ct state established,related accept"
    echo ""
    echo "    # Drop NEW inbound to the private-only services on any OTHER"
    echo "    # interface (e.g. a public IP). SSH and every other port are"
    echo "    # untouched — this guard can never lock you out."
    echo "    tcp dport { ${webui_port}, ${ollama_port} } ct state new counter drop"
    echo "  }"
    echo "}"
  }
}

# apply_inbound_guard — render and load the inbound guard. Warn (not die)
# where nft is unavailable so it never blocks a WebUI install on a box
# without nftables.
apply_inbound_guard() {
  if ! have nft; then
    warn "nft is not installed — cannot apply the inbound guard. Install nftables (scripts/install_dependencies.sh) so the WebUI/Ollama ports are not publicly reachable."
    return 0
  fi
  as_root mkdir -p "${NETMODE_DIR}"
  render_inbound_rules | as_root tee "${INBOUND_RULES_FILE}" >/dev/null
  as_root nft -f "${INBOUND_RULES_FILE}"
  ok "Inbound guard active: WebUI (port $(webui_port_from_env)) and Ollama (port $(ollama_port_from_env)) reachable only via loopback and Tailscale."
}

inbound_loaded() {
  as_root nft list table inet "${INBOUND_TABLE}" >/dev/null 2>&1
}

save_state() {
  as_root mkdir -p "${NETMODE_DIR}"
  printf '%s\n' "$1" | as_root tee "${NETMODE_STATE_FILE}" >/dev/null
}

table_loaded() {
  as_root nft list table inet "${NFT_TABLE}" >/dev/null 2>&1
}

install_service() {
  if ! systemd_available; then
    warn "systemd is not available — netmode will not persist across reboots on this machine."
    return 0
  fi
  info "Installing netmode boot-persistence service (${NETMODE_SERVICE})..."
  {
    echo "[Unit]"
    echo "Description=local-code-agent netmode (re-apply offline/online at boot)"
    echo "DefaultDependencies=no"
    echo "After=local-fs.target"
    echo "Before=network-pre.target"
    echo "Wants=network-pre.target"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    echo "ExecStart=${SCRIPT_DIR}/netmode.sh apply-saved"
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } | as_root tee "${NETMODE_SERVICE}" >/dev/null
  as_root systemctl daemon-reload
  as_root systemctl enable local-code-agent-netmode.service >/dev/null 2>&1 \
    || die "Could not enable local-code-agent-netmode.service — check: systemctl status local-code-agent-netmode"
  ok "Netmode now persists across reboots."
}

go_offline() {
  require_cmd nft
  step "Engaging internet kill switch (offline mode)"
  # Persist the state BEFORE applying the ruleset (fail-closed): if this is
  # interrupted, the boot service still re-applies the lockdown, rather than
  # the machine silently coming up ONLINE while the operator believes it is
  # locked.
  save_state offline
  write_rules_file
  as_root nft -f "${NFT_RULES_FILE}"
  apply_inbound_guard
  install_service
  ok "OFFLINE: new outbound connections are dropped; Tailscale + loopback stay open."
  info "Your phone still reaches WebUI/SSH over Tailscale. Toggle back with: sudo ${SCRIPT_DIR}/netmode.sh online"
}

go_online() {
  require_cmd nft
  step "Restoring normal internet access (online mode)"
  # Persist online first, then tear down the egress table, so an interrupt
  # converges to the operator's just-expressed intent (online) on reboot.
  save_state online
  if table_loaded; then
    as_root nft delete table inet "${NFT_TABLE}"
  fi
  apply_inbound_guard   # the inbound guard is always on, regardless of mode
  install_service
  ok "ONLINE: normal egress restored."
}

apply_saved() {
  # Called by systemd at boot: the inbound guard is ALWAYS on; the egress
  # lockdown depends on the last chosen mode.
  local state
  state="$(netmode_state)"
  info "Re-applying persisted netmode: ${state}"
  apply_inbound_guard
  if [[ "${state}" == "offline" ]]; then
    require_cmd nft
    [[ -f "${NFT_RULES_FILE}" ]] || write_rules_file
    as_root nft -f "${NFT_RULES_FILE}"
    ok "Offline ruleset re-applied."
  else
    if have nft && table_loaded; then
      as_root nft delete table inet "${NFT_TABLE}"
    fi
    ok "Online mode — no egress restrictions."
  fi
}

show_status() {
  step "Netmode status"
  local state
  state="$(netmode_state)"
  info "Persisted mode: ${state}"
  if have nft; then
    if table_loaded; then
      info "nftables: egress lockdown table 'inet ${NFT_TABLE}' is LOADED (egress restricted)."
    else
      info "nftables: no egress lockdown table loaded (egress unrestricted)."
    fi
    if inbound_loaded; then
      info "nftables: inbound guard 'inet ${INBOUND_TABLE}' is LOADED (WebUI/Ollama ports private-only)."
    else
      warn "inbound guard NOT loaded — WebUI/Ollama ports may be publicly reachable. Apply it with: sudo ${SCRIPT_DIR}/netmode.sh harden"
    fi
  else
    warn "nft is not installed — cannot inspect the ruleset."
  fi

  info "Live probe: curl --max-time 5 https://example.com ..."
  if curl -fsS --max-time 5 https://example.com -o /dev/null 2>/dev/null; then
    if [[ "${state}" == "offline" ]]; then
      err "Internet IS reachable although mode is offline — the lockdown is NOT active! Re-run: sudo ${SCRIPT_DIR}/netmode.sh offline"
      exit 1
    fi
    ok "Internet reachable — as expected in online mode."
  else
    if [[ "${state}" == "offline" ]]; then
      ok "Internet unreachable — the kill switch is working. (Tailscale access still works.)"
    else
      warn "Internet NOT reachable although mode is online — check the machine's network/DNS."
      exit 1
    fi
  fi
}

main() {
  case "${1:-}" in
    offline)          go_offline ;;
    online)           go_online ;;
    status)           show_status ;;
    harden)           apply_inbound_guard ;;
    apply-saved)      apply_saved ;;
    render-rules)     render_rules ;;          # print the offline egress ruleset (tests)
    render-inbound)   render_inbound_rules ;;  # print the inbound guard ruleset (tests)
    --install-service) install_service ;;
    *)
      cat <<EOF
Usage: sudo netmode.sh <offline|online|status|harden>

  offline   Kill-switch ON:  the AI stack loses ALL internet access, but your
            phone keeps reaching WebUI/SSH over Tailscale. Inference still
            works (models are local).
  online    Kill-switch OFF: normal internet access restored.
  status    Show the persisted mode and prove it with a live probe.
  harden    (Re)apply the always-on inbound guard so the WebUI/Ollama ports
            are reachable only over loopback and Tailscale, never publicly.

The chosen mode and the inbound guard persist across reboots.
EOF
      exit 1
      ;;
  esac
}

main "$@"
