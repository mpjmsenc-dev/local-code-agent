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
# harden:  (re)apply the always-on INBOUND guard (see below) AND install the
#          boot service that puts it back after a reboot.
#
# Inbound guard (always on, independent of offline/online): a second nft
# table drops NEW inbound connections to the Open WebUI and Ollama ports on
# every interface EXCEPT loopback and tailscale0. Those services bind all
# interfaces (Open WebUI uses docker --network=host), so without this guard
# a droplet's public IP would expose them; the guard makes the private-only
# guarantee real without touching SSH (port 22) or any other port, so it can
# never lock you out. It is applied at setup, whenever WebUI is (re)created,
# by 'lca apply' when .env moves a port out from under it, and re-applied on
# every boot.
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

# The guard must protect the EXACT ports the services actually bind. The rest
# of the stack derives those by sourcing .env (via load_env), which is quote-
# and inline-comment-tolerant. A bespoke sed parser here would disagree for
# ordinary .env styles (WEBUI_PORT="8080", trailing comments, CRLF) and could
# silently guard the wrong port — leaving the real one publicly exposed. So we
# source .env the same way, in a subshell (no writes, never creates .env, and
# stdout of the source is suppressed so render-* stays pure nft syntax).
webui_port_from_env() {
  local port=""
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    port="$( . <(tr -d '\r' < "${ENV_FILE}") >/dev/null 2>&1; printf '%s' "${WEBUI_PORT:-}" )"
  fi
  [[ "${port}" =~ ^[0-9]+$ ]] || port=3000
  printf '%s\n' "${port}"
}
ollama_port_from_env() {
  local url="" port=""
  if [[ -f "${ENV_FILE}" ]]; then
    # Reuse ollama_url's normalization (scheme/slash/0.0.0.0/default-port) so
    # the guarded port matches exactly what clients connect to.
    # shellcheck disable=SC1090
    url="$( . <(tr -d '\r' < "${ENV_FILE}") >/dev/null 2>&1; ollama_url )"
  fi
  port="${url##*:}"
  [[ "${port}" =~ ^[0-9]+$ ]] || port=11434
  printf '%s\n' "${port}"
}

# render_inbound_rules — print the always-on inbound guard to stdout. Drops
# NEW inbound to the WebUI/Ollama ports on every interface except loopback
# and tailscale0. SSH (22) and all other ports are left fully open, so this
# guard cannot lock anyone out.
render_inbound_rules() {
  local webui_port ollama_port p q seen port_list=""
  local ports=()
  webui_port="$(webui_port_from_env)"
  ollama_port="$(ollama_port_from_env)"
  # ENFORCE the "can never lock you out" invariant below instead of merely
  # asserting it. If WEBUI_PORT — or the port in OLLAMA_HOST — is 22 (a typo,
  # or someone fronting a service on the SSH port), the drop rule would
  # blackhole every NEW public SSH connection, and the boot service re-applies
  # the guard after each reboot: the box would then be reachable only from the
  # provider's recovery console. Refuse to guard 22, and say so on stderr so
  # the ruleset on stdout stays byte-clean for nft.
  for p in "${webui_port}" "${ollama_port}"; do
    [[ "${p}" =~ ^[0-9]+$ ]] || continue
    if (( p == 22 )); then
      warn "Refusing to add port 22 (SSH) to the inbound guard — that would lock you out of this machine. Change WEBUI_PORT / OLLAMA_HOST in .env, then re-run: sudo ${SCRIPT_DIR}/netmode.sh harden"
      continue
    fi
    seen=false
    for q in ${ports[@]+"${ports[@]}"}; do
      [[ "${q}" == "${p}" ]] && seen=true
    done
    [[ "${seen}" == "true" ]] || ports+=( "${p}" )
  done
  for p in ${ports[@]+"${ports[@]}"}; do
    port_list="${port_list:+${port_list}, }${p}"
  done
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
    echo "    # interface (e.g. a public IP). SSH (22) is filtered out of the"
    echo "    # set above before rendering, so this guard can never lock you out."
    if [[ -n "${port_list}" ]]; then
      echo "    tcp dport { ${port_list} } ct state new counter drop"
    else
      echo "    # No guardable ports configured (port 22 is never guarded)."
    fi
    echo "  }"
    echo "}"
  }
}

# apply_inbound_guard — render and load the inbound guard. Warn (not die)
# where nft is unavailable so it never blocks a WebUI install on a box
# without nftables.
apply_inbound_guard() {
  if ! have nft; then
    warn "nft is not installed — cannot apply the inbound guard. Install nftables (${SCRIPT_DIR}/scripts/install_dependencies.sh) so the WebUI/Ollama ports are not publicly reachable."
    return 0
  fi
  as_root mkdir -p "${NETMODE_DIR}"
  render_inbound_rules | as_root tee "${INBOUND_RULES_FILE}" >/dev/null
  as_root nft -f "${INBOUND_RULES_FILE}"
  # Name only what was actually put in the drop set. render_inbound_rules
  # REFUSES port 22 — so a WEBUI_PORT of 22 produced "WebUI (port 22) ...
  # reachable only via loopback and Tailscale" about a port deliberately left
  # wide open, which is the one sentence that must never be wrong here.
  local guard_wp guard_op guarded=()
  guard_wp="$(webui_port_from_env)"
  guard_op="$(ollama_port_from_env)"
  if [[ "${guard_wp}" != "22" ]]; then guarded+=("WebUI ${guard_wp}"); fi
  if [[ "${guard_op}" != "22" ]]; then guarded+=("Ollama ${guard_op}"); fi
  if (( ${#guarded[@]} )); then
    local joined="${guarded[*]}"
    ok "Inbound guard active: ${joined// /:} — reachable only via loopback and Tailscale."
  else
    warn "Inbound guard loaded but it drops nothing: every configured port is 22, which is never guarded so SSH can never be locked out. Change WEBUI_PORT / OLLAMA_HOST in .env, then: sudo lca harden"
  fi
}

# Returns 0 loaded, 1 not loaded, 2 cannot tell (no root/sudo). as_root would
# die() and abort `status` mid-run, leaving the operator with no answer at all
# about whether their ports are guarded — worse than an explicit "unknown".
inbound_loaded() {
  # can_root_now, not can_root: the latter is true whenever the sudo binary
  # exists, so a user who cannot actually escalate fell through to the nft
  # call, got nothing, and was told the guard is NOT loaded rather than that
  # nobody could look.
  can_root_now || return 2
  as_root nft list table inet "${INBOUND_TABLE}" >/dev/null 2>&1
}

save_state() {
  as_root mkdir -p "${NETMODE_DIR}"
  printf '%s\n' "$1" | as_root tee "${NETMODE_STATE_FILE}" >/dev/null
}

table_loaded() {
  as_root nft list table inet "${NFT_TABLE}" >/dev/null 2>&1
}

# install_service — write and enable the boot unit. Returns non-zero on
# failure instead of die()ing, so each caller can pick the severity: for
# setup.sh and offline/online this IS the job and failing it is fatal, but
# do_harden reaches here with the ports already closed, and exiting non-zero
# there would make both installers print "Could not apply the inbound guard"
# about a guard that is up — they turn any non-zero exit from 'harden' into
# exactly that sentence. Every step is checked explicitly rather than left to
# errexit, because errexit is suppressed for any command whose status is
# tested — including inside a subshell — and a silently swallowed tee is how
# a boot service ends up "installed" from a file that was never written.
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
    echo "ExecStart=\"${SCRIPT_DIR}/netmode.sh\" apply-saved"
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } | as_root tee "${NETMODE_SERVICE}" >/dev/null || return 1
  as_root systemctl daemon-reload || return 1
  as_root systemctl enable local-code-agent-netmode.service >/dev/null 2>&1 || return 1
  ok "Netmode now persists across reboots."
}

# require_service — install_service where failing is the end of the road.
require_service() {
  install_service \
    || die "Could not enable local-code-agent-netmode.service — check: systemctl status local-code-agent-netmode"
}

# do_harden — the user-facing "put the inbound guard back" command.
#
# Eight messages across this repo send people here when the guard is missing:
# 'netmode status', 'lca check' twice, both installers, TROUBLESHOOTING.md,
# DO.md and the SSH-port refusal above. The usage text at the bottom of this
# file then tells them "the inbound guard persist[s] across reboots" — which
# was only true if you arrived by setup.sh, offline or online, the three paths
# that also install the boot unit. Reached the documented way, harden loaded
# the ruleset for THIS boot and nothing else, so the ports that had just been
# closed went public again at the next reboot.
#
# 'lca check' did catch that, but only on the NEXT run, and it then named
# --install-service — an internal flag this script's own usage does not list.
# One command that finishes the job beats a two-round recovery through a flag
# the user cannot look up.
#
# The guard goes on FIRST, and a systemd problem is only ever a warning here:
# closing the ports is what was actually asked for, a machine with a broken
# systemd still deserves it, and both installers turn ANY non-zero exit from
# 'harden' into "Could not apply the inbound guard — the port may be publicly
# reachable", which would be a false alarm about a guard that is up.
do_harden() {
  apply_inbound_guard
  install_service \
    || warn "The inbound guard is applied, but its boot service could not be installed — it will NOT be re-applied after a reboot, and the ports become public then. Check: systemctl status local-code-agent-netmode"
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
  require_service
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
  require_service
  ok "ONLINE: normal egress restored."
}

apply_saved() {
  # Called by systemd at boot: the inbound guard is ALWAYS on; the egress
  # lockdown depends on the last chosen mode.
  local state inbound_rc
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
  local state inbound_rc
  state="$(netmode_state)"
  info "Persisted mode: ${state}"
  if have nft; then
    if table_loaded; then
      info "nftables: egress lockdown table 'inet ${NFT_TABLE}' is LOADED (egress restricted)."
    else
      info "nftables: no egress lockdown table loaded (egress unrestricted)."
    fi
    # '|| inbound_rc=$?', not 'inbound_loaded; inbound_rc=$?'. The second form
    # leaves inbound_loaded as an untested command, so under 'set -e' a
    # non-zero return kills the script HERE — before the case below that exists
    # to report it, and before the live probe. inbound_loaded returns 1 for
    # "not loaded" and 2 for "cannot tell", which means 'netmode.sh status'
    # printed three lines and stopped, with exit 1 and no explanation, in
    # exactly the two situations anyone runs it for. Observed on a box with no
    # guard loaded: the "inbound guard NOT loaded" warning never appeared.
    inbound_rc=0
    inbound_loaded || inbound_rc=$?
    case "${inbound_rc}" in
      0) info "nftables: inbound guard 'inet ${INBOUND_TABLE}' is LOADED (WebUI/Ollama ports private-only)." ;;
      2) warn "Cannot inspect nftables without root or sudo — the inbound guard state is UNKNOWN. Re-run as root: sudo ${SCRIPT_DIR}/netmode.sh status" ;;
      *) warn "inbound guard NOT loaded — WebUI/Ollama ports may be publicly reachable. Apply it with: sudo ${SCRIPT_DIR}/netmode.sh harden" ;;
    esac
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

# usage — printed for --help (exit 0) and for anything unrecognised (exit 1).
# One copy, because the two used to be the same branch: asking a command that
# edits the firewall what it does came back as an error.
usage() {
  cat <<EOF
Usage: sudo lca <offline|online|status|harden>       (or netmode.sh directly)

  offline   Kill-switch ON:  the AI stack loses ALL internet access, but your
            phone keeps reaching WebUI/SSH over Tailscale. Inference still
            works (models are local).
  online    Kill-switch OFF: normal internet access restored.
  status    Show the persisted mode and prove it with a live probe.
  harden    (Re)apply the always-on inbound guard so the WebUI/Ollama ports
            are reachable only over loopback and Tailscale, never publicly —
            now, and again after every reboot.

The chosen mode and the inbound guard persist across reboots.
EOF
}

main() {
  # Everything after the subcommand used to be ignored, and bin/lca forwards
  # trailing arguments verbatim — so 'lca harden --help' reached
  # 'netmode.sh harden --help' and APPLIED THE FIREWALL, which is the one
  # answer a question must never get. 'lca offline --typo' went the same way.
  # No subcommand here takes an argument, so a second one is always a mistake.
  case "${2:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown extra argument: ${2}" ;;
  esac
  case "${1:-}" in
    offline)          go_offline ;;
    online)           go_online ;;
    status)           show_status ;;
    harden)           do_harden ;;
    apply-saved)      apply_saved ;;
    render-rules)     render_rules ;;          # print the offline egress ruleset (tests)
    render-inbound)   render_inbound_rules ;;  # print the inbound guard ruleset (tests)
    --install-service) require_service ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage; exit 1 ;;
  esac
}

main "$@"
