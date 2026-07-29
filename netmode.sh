#!/usr/bin/env bash
# netmode.sh — the one-command internet kill switch: offline | online | status
#
# offline: nftables egress lockdown — every NEW outbound connection on the
#          WAN side is dropped, EXCEPT loopback and the Tailscale path
#          (tailscale0 interface, tailscaled's fwmark-tagged control/data
#          traffic, WireGuard/STUN ports, plus DNS so tailscaled can find
#          its coordination server). Your phone keeps reaching Open WebUI
#          and SSH over Tailscale; Ollama, WebUI, aider, apt and everything
#          else have ZERO internet. Inference is unaffected — models are
#          local.
# online:  restore normal egress.
# status:  print the persisted mode AND prove it with a live probe.
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
load_env

NFT_TABLE="lca_netmode"
NFT_RULES_FILE="${NETMODE_DIR}/netmode.nft"
NETMODE_SERVICE=/etc/systemd/system/local-code-agent-netmode.service

write_rules_file() {
  as_root mkdir -p "${NETMODE_DIR}"
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
    echo "}"
  } | as_root tee "${NFT_RULES_FILE}" >/dev/null
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
  write_rules_file
  as_root nft -f "${NFT_RULES_FILE}"
  save_state offline
  install_service
  ok "OFFLINE: new outbound connections are dropped; Tailscale + loopback stay open."
  info "Your phone still reaches WebUI/SSH over Tailscale. Toggle back with: sudo ${SCRIPT_DIR}/netmode.sh online"
}

go_online() {
  require_cmd nft
  step "Restoring normal internet access (online mode)"
  if table_loaded; then
    as_root nft delete table inet "${NFT_TABLE}"
  fi
  save_state online
  install_service
  ok "ONLINE: normal egress restored."
}

apply_saved() {
  # Called by systemd at boot: re-apply whatever mode was last chosen.
  local state
  state="$(netmode_state)"
  info "Re-applying persisted netmode: ${state}"
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
      info "nftables: lockdown table 'inet ${NFT_TABLE}' is LOADED (egress restricted)."
    else
      info "nftables: no lockdown table loaded (egress unrestricted)."
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
    apply-saved)      apply_saved ;;
    --install-service) install_service ;;
    *)
      cat <<EOF
Usage: sudo netmode.sh <offline|online|status>

  offline   Kill-switch ON:  the AI stack loses ALL internet access, but your
            phone keeps reaching WebUI/SSH over Tailscale. Inference still
            works (models are local).
  online    Kill-switch OFF: normal internet access restored.
  status    Show the persisted mode and prove it with a live probe.

The chosen mode persists across reboots.
EOF
      exit 1
      ;;
  esac
}

main "$@"
