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
  if [[ "$(head -1 "$2")" == "#!/usr/sbin/nft -f" ]]; then
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
README_MD="$(cd "$(dirname "$0")/.." && pwd)/README.md"
limits="$(sed -n '/^\*\*Honest limitations\*\*/,/^\*\*Your responsibilities/p' "${README_MD}")"
undocumented=""
while read -r port; do
  [[ -n "${port}" ]] || continue
  grep -qF "${port}" <<<"${limits}" || undocumented="${undocumented} ${port}"
done < <(grep -oE '(udp|tcp) (dport|sport) \{?[ 0-9,]+\}?' "${RULES}" \
           | grep -oE '[0-9]+' | sort -un)
if [[ -z "${undocumented}" ]]; then
  t_ok "every port the offline ruleset accepts is listed in the README's limitations"
else
  t_fail "offline mode opens port(s) the README never mentions:${undocumented}"
fi

echo "# OFFLINE also covers forwarded (docker-bridge) traffic"
contains "forward hook present"             "${RULES}" 'hook forward'
contains "forward allows tailscale0"        "${RULES}" 'oifname "tailscale0" accept'

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

echo
if (( FAILED > 0 )); then
  echo "RESULT: ${FAILED} test(s) FAILED"
  exit 1
fi
echo "RESULT: all netmode tests passed"
