#!/usr/bin/env bash
# tests/test-netmode.sh — validate the netmode OFFLINE ruleset without ever
# applying it:
#   1. content assertions: the safety-critical rules must be present
#   2. kernel validation: nft --check parses and evaluates the ruleset in
#      check-only mode (nothing is loaded)
# Needs root (or sudo) + nft for step 2; degrades to a clear skip otherwise.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"

FAILED=0
t_ok()   { printf '%s\n' "ok   - $*"; }
t_fail() { printf '%s\n' "FAIL - $*"; FAILED=$((FAILED+1)); }

# What every render-* must put on its first line, and nothing may precede.
# Shared, so the purity check inside render_with_env and the one applied to the
# two renders below cannot drift apart.
NFT_SHEBANG='#!/usr/sbin/nft -f'

RULES="$(mktemp)"
INBOUND="$(mktemp)"
trap 'rm -rf "${RULES}" "${INBOUND}" "${SSH_ALL_FILE:-}"' EXIT
"${REPO}/netmode.sh" render-rules > "${RULES}"
"${REPO}/netmode.sh" render-inbound > "${INBOUND}"

# render_with_env ENV_CONTENT — render the inbound guard as if .env said this.
#
# netmode.sh resolves .env from its own location, so varying it used to mean
# writing ${REPO}/.env — which would destroy a developer's real one. The tests
# that did so guarded with "skip if .env exists", and the effect was that the
# SSH-lockout invariant and the custom-port checks ran ONLY in CI. A
# security invariant that skips on the maintainer's machine is exactly the one
# you want running everywhere, and 'make gates' before a push exercised
# neither.
#
# So render from a throwaway copy of the repo instead. Nothing in the real
# checkout is touched, and the assertions now run unconditionally.
render_with_env() {
  local sandbox rendered
  sandbox="$(mktemp -d)"
  ( cd "${REPO}" && tar -c --exclude=.venv --exclude=.git --exclude=backups . ) \
    | tar -x -C "${sandbox}"
  printf '%s\n' "$1" > "${sandbox}/.env"
  rendered="$("${sandbox}/netmode.sh" render-inbound 2>/dev/null || true)"
  rm -rf "${sandbox}"
  # The '|| true' above keeps a failed render from aborting the suite, which
  # means an empty string flows into assertions that are mostly of the form
  # "this must NOT appear" — and those pass for the wrong reason. Measured
  # against an empty render: of the three SSH-lockout checks, "WEBUI_PORT=22 is
  # refused" and "no drop rule when every port is 22" both pass vacuously, and
  # only "the other configured port is still guarded" notices. The invariant
  # stays guarded, but by an incidental assertion rather than the two named for
  # it, and it would go unguarded the moment that one was reworded. Say it
  # here, once, so every caller inherits the check.
  if [[ -z "${rendered}" ]]; then
    t_fail "render_with_env produced nothing — 'netmode.sh render-inbound' failed for this .env, so the assertions below would pass on an empty string"
  # Stdout purity, here and not only on the two default renders below.
  #
  # These are the renders with an UNUSUAL .env, so they are the ones that make
  # netmode.sh say something: WEBUI_PORT=22 takes the refusal branch, which
  # warns. That warning goes to stderr precisely so the ruleset on stdout stays
  # byte-clean for nft — and this function discards stderr, so nothing else in
  # the suite could tell if it moved. Every assertion downstream is a grep,
  # which a prepended line does not disturb; nft is not so forgiving, and the
  # boot service re-renders this file on every reboot.
  elif [[ "$(head -1 <<<"${rendered}")" != "${NFT_SHEBANG}" ]]; then
    t_fail "render_with_env: stdout is not pure nft syntax — first line is '$(head -1 <<<"${rendered}")', not '${NFT_SHEBANG}'"
  fi
  printf '%s\n' "${rendered}"
}

contains() {  # desc file needle
  if grep -qF "$3" "$2"; then t_ok "$1"; else t_fail "$1 — missing: $3"; fi
}
absent() {    # desc file pattern
  if grep -qE "$3" "$2"; then t_fail "$1 — unexpectedly present: $3"; else t_ok "$1"; fi
}

echo "# stdout purity: render-* must emit nft syntax and nothing else"
# (CI caught load_env's '[info] Created .env' notice leaking into the rules
# on a fresh checkout — this guards against any such stdout contamination.)
shebang_ok() {  # desc file
  if [[ "$(head -1 "$2")" == "${NFT_SHEBANG}" ]]; then
    t_ok "$1"
  else
    t_fail "$1 (got: $(head -1 "$2"))"
  fi
}
shebang_ok "offline ruleset first line is the nft shebang" "${RULES}"
shebang_ok "inbound ruleset first line is the nft shebang" "${INBOUND}"

echo "# OFFLINE egress: the Tailscale path must never be cut"
contains "loopback egress allowed"          "${RULES}" 'oifname "lo" accept'
contains "tailscale0 egress allowed"        "${RULES}" 'oifname "tailscale0" accept'
contains "tailscaled fwmark allowed"        "${RULES}" 'meta mark & 0x00ff0000 == 0x00080000 accept'
contains "WireGuard port allowed"           "${RULES}" 'udp dport 41641 accept'
contains "established replies allowed"       "${RULES}" 'ct state established,related accept'
contains "new outbound connections dropped" "${RULES}" 'ct state new counter drop'

echo "# every hole the offline ruleset opens must be named in the README"
# The README's "Honest limitations" tells the reader exactly which ports stay
# open in offline mode, and that list is the whole basis for judging what the
# kill switch does and does not guarantee. It was incomplete: DNS, STUN and
# WireGuard were named, while DHCP (67/68/547) and ICMPv6 neighbour discovery
# were accepted by the ruleset and mentioned nowhere.
#
# This compares the two directly, so the failure modes it catches are both:
# a new hole opened without documenting it, and a documented hole quietly
# removed — the second is how someone gets stranded on a remote VM when
# Tailscale cannot re-resolve after a reboot.
#
# Driven off every accept RULE, not off port numbers. The version this replaces
# extracted '(udp|tcp) (dport|sport) N' and nothing else, so two of the holes
# in the ruleset were invisible to it — including the ICMPv6 rule its own
# comment cites as the original bug. Deleting "and ICMPv6 neighbour discovery"
# from the README left it green, and so would a new 'icmpv6 type echo-request
# accept' or a second fwmark exemption.
#
# The load-bearing part is the default: a rule whose shape is not in the case
# below FAILS. Every hole therefore has to be classified by a person once —
# either "the README must name this" or "this never leaves the box, and here is
# why" — instead of being skipped for not looking like a port.
README_MD="$(cd "$(dirname "$0")/.." && pwd)/README.md"
limits="$(sed -n '/^\*\*Honest limitations\*\*/,/^\*\*Your responsibilities/p' "${README_MD}")"
undocumented=""
unclassified=""
while IFS= read -r rule; do
  [[ -n "${rule}" ]] || continue
  needs=()
  case "${rule}" in
    # Traffic that never reaches another machine, so there is no hole to
    # disclose: loopback, and replies on connections something already allowed.
    'oifname "lo" accept')             ;;
    'ct state established,related accept') ;;
    # The Tailscale path is the point of offline mode, named all over the
    # README rather than buried in this one paragraph.
    'oifname "tailscale0" accept')     ;;
    # Everything below can carry packets to an arbitrary host.
    'meta mark'*)                      needs=(fwmark) ;;
    'icmpv6 type'*)                    needs=(ICMPv6) ;;
    *' dport '*|*' sport '*)           mapfile -t needs < <(grep -oE '[0-9]+' <<<"${rule}") ;;
    *) unclassified="${unclassified}
    ${rule}"; continue ;;
  esac
  for need in ${needs[0]+"${needs[@]}"}; do
    grep -qF "${need}" <<<"${limits}" || undocumented="${undocumented} ${need}"
  done
done < <(sed -n 's/^ *\(.*[^ ] accept\)$/\1/p' "${RULES}" | sort -u)
if [[ -n "${unclassified}" ]]; then
  t_fail "the offline ruleset accepts traffic this test does not know how to judge — classify it above, then say so in the README if it can leave the box:${unclassified}"
elif [[ -n "${undocumented}" ]]; then
  t_fail "offline mode opens hole(s) the README never mentions:${undocumented}"
else
  t_ok "every hole the offline ruleset opens is listed in the README's limitations"
fi

echo "# OFFLINE also covers forwarded (docker-bridge) traffic"
# Scoped to the forward chain. These read the WHOLE file, and the egress chain
# emits the identical 'oifname "tailscale0" accept' — so deleting it from the
# forward chain, which is what carries docker-bridge container traffic, left
# this assertion passing on the egress copy. The one rule that keeps a
# container reachable over Tailscale while offline was guarded by a grep that
# could not tell the two chains apart.
chain_block() {  # file chain-name
  awk -v want="$2" '
    $0 ~ ("chain " want " \\{") { inb = 1; next }
    inb && /^  \}/               { exit }
    inb                          { print }' "$1"
}
in_chain() {  # desc file chain needle
  if grep -qF "$4" <<<"$(chain_block "$2" "$3")"; then
    t_ok "$1"
  else
    t_fail "$1 — missing from the $3 chain: $4"
  fi
}
contains "forward hook present"             "${RULES}" 'hook forward'
in_chain  "forward allows tailscale0"       "${RULES}" forward 'oifname "tailscale0" accept'
in_chain  "forward drops new connections"   "${RULES}" forward 'ct state new counter drop'
in_chain  "egress still allows tailscale0"  "${RULES}" egress  'oifname "tailscale0" accept'

echo "# INBOUND guard: private-only services, SSH untouched"
contains "inbound input hook present"       "${INBOUND}" 'type filter hook input'
contains "inbound allows loopback"          "${INBOUND}" 'iifname "lo" accept'
contains "inbound allows tailscale0"        "${INBOUND}" 'iifname "tailscale0" accept'
contains "inbound drops the service ports"  "${INBOUND}" 'ct state new counter drop'
contains "inbound targets tcp dport set"    "${INBOUND}" 'tcp dport {'
# SSH (22) must never appear in the inbound guard — proves it can't lock you out.
absent  "inbound never filters SSH (22)"    "${INBOUND}" '(\{|[[:space:],]|dport )22([[:space:],]|\})'

echo "# rule ORDER: in every chain the drop is the last rule (no dead accepts after it)"
order_ok() {  # desc file
  if awk '
    /ct state new counter drop/ { dropped=1; next }
    dropped && /accept/         { bad=1 }
    dropped && /}/              { dropped=0 }
    END { exit bad?1:0 }
  ' "$2"; then
    t_ok "$1"
  else
    t_fail "$1 (an accept follows a drop — dead rule)"
  fi
}
order_ok "offline: drop is the last rule in every chain" "${RULES}"
order_ok "inbound: drop is the last rule in every chain" "${INBOUND}"

echo "# inbound guard reads quoted/annotated .env ports like load_env (not a sed parser)"
# Black-box: a quoted WEBUI_PORT with an inline comment must still be the port
# the guard drops — otherwise the real public port would be left exposed.
QG="$(render_with_env 'WEBUI_PORT="8080" # avoid clash
OLLAMA_HOST="0.0.0.0:11500"')"
if grep -qE 'dport \{[^}]*\b8080\b' <<<"${QG}"; then t_ok "quoted WEBUI_PORT 8080 is guarded"; else t_fail "quoted WEBUI_PORT 8080 NOT guarded ($(grep -o 'tcp dport [^}]*}' <<<"${QG}"))"; fi
if grep -qE 'dport \{[^}]*\b11500\b' <<<"${QG}"; then t_ok "quoted OLLAMA_HOST port 11500 is guarded"; else t_fail "quoted OLLAMA_HOST port 11500 NOT guarded"; fi
if grep -qE 'dport \{[^}]*\b3000\b' <<<"${QG}"; then t_fail "stale default 3000 guarded despite WEBUI_PORT=8080"; else t_ok "no stale default port when WEBUI_PORT is set"; fi

echo "# SSH invariant: port 22 must NEVER reach the inbound drop set"
# The guard's whole promise is that it cannot lock you out. A WEBUI_PORT (or
# OLLAMA_HOST port) of 22 — a typo, or a service deliberately fronted on the
# SSH port — would otherwise blackhole every NEW public SSH connection, and the
# boot service re-applies the guard after each reboot, leaving only the
# provider's recovery console. This asserts the invariant is ENFORCED, not just
# claimed in a comment.
SSH_ONE="$(render_with_env 'WEBUI_PORT=22
OLLAMA_HOST="127.0.0.1:11434"')"
if grep -qE 'dport \{[^}]*\b22\b' <<<"${SSH_ONE}"; then
  t_fail "WEBUI_PORT=22 reached the drop set — this would lock SSH out"
else
  t_ok "WEBUI_PORT=22 is refused (SSH is never guarded)"
fi
if grep -qE 'dport \{[^}]*\b11434\b' <<<"${SSH_ONE}"; then
  t_ok "the other configured port is still guarded when one is 22"
else
  t_fail "dropping port 22 also lost the legitimate port"
fi

# Every configured port = 22 -> no drop rule at all, and the ruleset must
# still be syntactically valid (an empty '{ }' set would break nft).
SSH_ALL="$(render_with_env 'WEBUI_PORT=22
OLLAMA_HOST="127.0.0.1:22"')"
if grep -q 'tcp dport' <<<"${SSH_ALL}"; then
  t_fail "a drop rule was emitted when every configured port was 22"
else
  t_ok "no drop rule emitted when every configured port is 22"
fi
# Kept for the kernel check below, where the NFT array is defined.
SSH_ALL_FILE="$(mktemp)"
printf '%s\n' "${SSH_ALL}" > "${SSH_ALL_FILE}"

echo "# kernel validation via nft --check (nothing is applied)"
NFT=()
if command -v nft >/dev/null 2>&1; then
  if [[ "${EUID}" -eq 0 ]]; then
    NFT=(nft)
  elif command -v sudo >/dev/null 2>&1; then
    NFT=(sudo -n nft)
  fi
fi
nft_check() {  # desc file
  if "${NFT[@]}" --check -f "$2"; then t_ok "$1"; else t_fail "$1"; fi
}
if [[ "${#NFT[@]}" -eq 0 ]]; then
  echo "skip - nft (as root) not available; content checks above still ran"
else
  nft_check "nft --check accepts the offline ruleset" "${RULES}"
  nft_check "nft --check accepts the inbound ruleset" "${INBOUND}"
  # An all-22 config yields a guard with NO drop rule; an empty '{ }' set would
  # be a syntax error, so prove the rendered ruleset still parses.
  if [[ -n "${SSH_ALL_FILE:-}" && -f "${SSH_ALL_FILE:-}" ]]; then
    nft_check "nft --check accepts the guard when every configured port is 22" "${SSH_ALL_FILE}"
  fi
fi

echo "# write_rules_file — the step that puts the ruleset on disk"
# Everything above renders. Nothing ran the function that WRITES, because the
# only ways to reach it are 'netmode.sh offline' and 'harden', which a test
# suite must never do — so the file this project reloads at every boot was
# produced by code no test had executed. netmode.sh is sourceable now (the
# same guard restore.sh and apply.sh use), so it can be called directly with
# NETMODE_DIR pointed at a sandbox.
#
# Nothing here touches nft: write_rules_file only writes a file. as_root is
# stubbed to run the command unchanged, since a sandbox path needs no root.
WRF_SB="$(mktemp -d)"
trap 'rm -rf "${RULES}" "${INBOUND}" "${SSH_ALL_FILE:-}" "${WRF_SB}"' EXIT
wrf_run() {   # ENV-PREP -> writes ${WRF_SB}/netmode.nft, prints nothing
  bash -c '
    set -euo pipefail
    as_root() { "$@"; }
    source "$1"
    NETMODE_DIR="$2"; NFT_RULES_FILE="$2/netmode.nft"
    '"$1"'
    write_rules_file
  ' _ "${REPO}/netmode.sh" "${WRF_SB}" >/dev/null 2>&1
}
if wrf_run ':' && [[ -s "${WRF_SB}/netmode.nft" ]]; then
  t_ok "write_rules_file writes the ruleset"
else
  t_fail "write_rules_file did not produce a ruleset"
fi
# What it wrote must be exactly what render-rules prints — a writer that
# silently drops or reorders lines is the failure this cannot otherwise see.
if diff -q "${RULES}" "${WRF_SB}/netmode.nft" >/dev/null 2>&1; then
  t_ok "...byte for byte what render-rules prints"
else
  t_fail "the written ruleset differs from the rendered one"
fi
# ...and a render that fails must leave the previous ruleset alone, rather than
# replacing it with however much arrived before the error. nft will not load a
# partial ruleset, and this file is what the boot service feeds it.
printf 'PREVIOUS RULESET\n' > "${WRF_SB}/netmode.nft"
if wrf_run 'render_rules() { return 1; }'; then
  t_fail "a failed render was reported as a successful write"
else
  t_ok "a failed render does not report success"
fi
if [[ "$(cat "${WRF_SB}/netmode.nft")" == "PREVIOUS RULESET" ]]; then
  t_ok "...and leaves the previous ruleset untouched"
else
  t_fail "a failed render destroyed the ruleset already on disk"
fi
if compgen -G "${WRF_SB}/*.lca-new" >/dev/null; then
  t_fail "a temp file was left behind in ${WRF_SB}"
else
  t_ok "...leaving no temp file behind"
fi

echo
if (( FAILED > 0 )); then
  echo "RESULT: ${FAILED} test(s) FAILED"
  exit 1
fi
echo "RESULT: all netmode tests passed"
