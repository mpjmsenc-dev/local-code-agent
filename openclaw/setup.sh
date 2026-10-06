#!/usr/bin/env bash
# openclaw/setup.sh — the browser dashboard: OpenClaw, locked down to this
# repo's own plugin (openclaw/lca-plugin), as 'lca dashboard'.
#
#   sudo lca dashboard setup     install or update it, and (re)write its config
#   lca dashboard url            where it is
#   lca dashboard status         is it up, where, and what it may do
#   sudo lca dashboard restart   restart it
#
# What it is, and what it is not. OpenClaw is a general-purpose agent gateway;
# here it is cut down to one job, and every cut is enforced by OpenClaw's own
# config, not by a prompt:
#
#   model      only the local Ollama, the agent's model as it is already loaded
#              (same name, same window), so the dashboard never evicts a project
#   tools      only the lca plugin's (tools.profile minimal + alsoAllow lca,
#              every core group denied): no shell, no files, no browser, no web
#   plugins    an exclusive allowlist: ollama and lca. Every hosted provider,
#              channel, browser and canvas plugin stays unloaded
#   skills     none (agents.defaults.skills: []), no installs, no ClawHub
#   channels   none: no Telegram, WhatsApp or anything else
#   network    it listens on the Tailscale address (and loopback) only, behind a
#              password, and that port is in the inbound guard. It runs as the
#              owner with no new privileges (no sudo from inside it, ever), and
#              may only open connections to this machine and the tailnet
#
# The password is generated once into ~/.openclaw-dashboard-password (mode
# 600). Change it there and run setup again; it is never printed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# lib.sh's messages name commands from the checkout's root.
# shellcheck disable=SC2034
SCRIPT_DIR="${REPO}"
# shellcheck source=../scripts/lib.sh
source "${REPO}/scripts/lib.sh"
load_env

# Pinned: what was measured on the reference box, and the checksums of exactly
# those builds. Node's from nodejs.org's SHASUMS256.txt; OpenClaw's is the
# npm registry's integrity for the package.
OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.9.8}"
OPENCLAW_INTEGRITY="${OPENCLAW_INTEGRITY:-sha512-G+JkNUhtpDE3cXR4AEi2NyyG9fqI/T2WUSl8ZnR8AATH8Dh1kC3qYFL7wwPoZtgHiP/cszA86PEiE0PDysxb9Q==}"
OPENCLAW_NODE_VERSION="${OPENCLAW_NODE_VERSION:-24.21.0}"
OPENCLAW_NODE_SHA256="${OPENCLAW_NODE_SHA256:-fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6}"

NODE_BIN="${OPENCLAW_DIR}/node/bin/node"
NPM_BIN="${OPENCLAW_DIR}/node/bin/npm"
OPENCLAW_BIN="${OPENCLAW_DIR}/app/bin/openclaw"
PLUGIN_DIR="${REPO}/openclaw/lca-plugin"

usage() {
  cat <<EOF
Usage: lca dashboard setup | url | status | restart

The browser dashboard: OpenClaw on this machine's Tailscale address, port
${OPENCLAW_PORT}, behind a password, locked down to local-code-agent's own
plugin. From it: start a project from a pasted or uploaded spec, follow every
project live (the Projects tab), stop and resume, read the summary, decisions
and review; and the server's health, models, CPU, RAM and disk.

  setup     (sudo) install or update it and write its config; turns it on
  url       the address to open
  status    whether it is running, and the address
  restart   (sudo) restart it

The password is in ~/.openclaw-dashboard-password (mode 600).
EOF
}

owner_home() { getent passwd "$1" | cut -d: -f6; }

# --- install --------------------------------------------------------------------
installed_version() {
  [[ -x "${OPENCLAW_BIN}" && -x "${NODE_BIN}" ]] || return 1
  PATH="${OPENCLAW_DIR}/node/bin:${PATH}" OPENCLAW_NO_AUTO_UPDATE=1 DO_NOT_TRACK=1 \
    timeout 60 "${OPENCLAW_BIN}" --version 2>/dev/null | awk '{ print $2; exit }'
}

install_node() {
  local tmp="$1" tarball="node-v${OPENCLAW_NODE_VERSION}-linux-x64.tar.xz"
  [[ "$("${NODE_BIN}" -v 2>/dev/null || true)" == "v${OPENCLAW_NODE_VERSION}" ]] && return 0
  info "Downloading Node ${OPENCLAW_NODE_VERSION}..."
  curl -fsSL -o "${tmp}/${tarball}" "https://nodejs.org/dist/v${OPENCLAW_NODE_VERSION}/${tarball}" \
    || die "Could not download Node ${OPENCLAW_NODE_VERSION}."
  printf '%s  %s\n' "${OPENCLAW_NODE_SHA256}" "${tmp}/${tarball}" | sha256sum -c --quiet - \
    || die "Node's checksum does not match the pinned one; nothing was installed."
  as_root mkdir -p "${OPENCLAW_DIR}"
  as_root tar -xJf "${tmp}/${tarball}" -C "${OPENCLAW_DIR}"
  as_root ln -sfn "${OPENCLAW_DIR}/node-v${OPENCLAW_NODE_VERSION}-linux-x64" "${OPENCLAW_DIR}/node"
  ok "Node ${OPENCLAW_NODE_VERSION} in ${OPENCLAW_DIR}/node"
}

# install_openclaw TMP — the pinned package, checked against the pinned
# integrity, installed root-owned with install scripts OFF; then only the
# scripts it needs, by name: three well-known dependencies' and OpenClaw's own
# postinstall (it prunes its bundled plugins, offline).
install_openclaw() {
  local tmp="$1" tgz got
  [[ "$(installed_version || true)" == "${OPENCLAW_VERSION}" ]] && { ok "OpenClaw ${OPENCLAW_VERSION} is installed"; return 0; }
  info "Downloading OpenClaw ${OPENCLAW_VERSION}..."
  ( cd "${tmp}" && PATH="${OPENCLAW_DIR}/node/bin:${PATH}" "${NPM_BIN}" pack --silent "openclaw@${OPENCLAW_VERSION}" >/dev/null ) \
    || die "Could not download OpenClaw ${OPENCLAW_VERSION}."
  tgz="${tmp}/openclaw-${OPENCLAW_VERSION}.tgz"
  got="sha512-$(openssl dgst -sha512 -binary "${tgz}" | base64 -w0)"
  [[ "${got}" == "${OPENCLAW_INTEGRITY}" ]] || die "OpenClaw's package does not match the pinned integrity; nothing was installed."
  as_root env PATH="${OPENCLAW_DIR}/node/bin:/usr/bin:/bin" "${NPM_BIN}" install -g --prefix "${OPENCLAW_DIR}/app" \
    --ignore-scripts --no-fund --no-audit "${tgz}" >/dev/null || die "npm could not install OpenClaw."
  ( cd "${OPENCLAW_DIR}/app/lib/node_modules/openclaw" \
    && as_root env PATH="${OPENCLAW_DIR}/node/bin:/usr/bin:/bin" "${NPM_BIN}" rebuild esbuild koffi protobufjs >/dev/null 2>&1 \
    && as_root env PATH="${OPENCLAW_DIR}/node/bin:/usr/bin:/bin" "${NODE_BIN}" scripts/postinstall-bundled-plugins.mjs >/dev/null ) \
    || die "OpenClaw's install steps failed."
  [[ "$(installed_version || true)" == "${OPENCLAW_VERSION}" ]] || die "OpenClaw ${OPENCLAW_VERSION} does not run after installing."
  ok "OpenClaw ${OPENCLAW_VERSION} in ${OPENCLAW_DIR}/app"
}

# --- the config -------------------------------------------------------------------
# openclaw_config OWNER_HOME — the whole openclaw.json, as JSON (a subset of
# the JSON5 it reads). Nothing in it is a secret: the password is read from the
# unit's environment file.
#
# The model is asked for exactly as everything else asks for it, so its runner
# is shared and never reloaded: the same name and window, and shift and
# truncate at Ollama's defaults. OpenClaw sends shift:false to local servers
# unless told otherwise, and Ollama starts a second runner without context
# shift for that: measured, a 51 GB reload of 5.5 minutes for one dashboard
# message, and another for the project's next request (2026-10-06).
openclaw_config() {
  local home="$1" model ctx
  model="$(agent_model_name)"
  ctx="$(agent_model_context)"
  jq -n --arg home "${home}" --arg plugin "${PLUGIN_DIR}" --arg model "${model}" --argjson ctx "${ctx}" \
        --argjson port "${OPENCLAW_PORT}" --arg ollama "$(ollama_url)" --arg lca "${REPO}" \
        --arg projects "${AGENT_PROJECTS_DIR%/}" --argjson timeout "$(agent_request_timeout)" '
  {
    gateway: {
      mode: "local", port: $port, bind: "tailnet",
      auth: { mode: "password", password: { source: "env", provider: "default", id: "OPENCLAW_GATEWAY_PASSWORD" } },
      tailscale: { mode: "off" },
      terminal: { enabled: false },
      cliAgents: { enabled: false },
      uploads: { enabled: false },
      controlUi: { automaticallyFetchFavicons: false, communityInvite: false, sessionObserver: false, embedSandbox: "trusted" }
    },
    update: { checkOnStart: false, auto: { enabled: false } },
    telemetry: { enabled: false },
    discovery: { mdns: { mode: "off" } },
    browser: { enabled: false },
    cron: { enabled: false },
    commands: { bash: false, config: false, plugins: false, mcp: false, debug: false, restart: false },
    skills: {
      allowBundled: ["none"],
      load: { watch: false },
      install: { allowUploadedArchives: false },
      workshop: { autonomous: { mode: "off" }, approvalPolicy: "pending" },
      limits: { maxSkillsInPrompt: 0 }
    },
    plugins: {
      allow: ["ollama", "lca"],
      load: { paths: [$plugin] },
      slots: { memory: "none" },
      entries: {
        ollama: { config: { discovery: { enabled: false } } },
        lca: { enabled: true, config: { lcaDir: $lca, projectsDir: $projects, specsDir: ($home + "/specs"),
                                        openclawBin: "/opt/openclaw/app/bin/openclaw" } }
      }
    },
    models: {
      catalogRefresh: { enabled: false },
      providers: {
        ollama: {
          baseUrl: $ollama, api: "ollama", apiKey: "ollama-local", timeoutSeconds: $timeout,
          models: [{
            id: $model, name: $model, reasoning: false, input: ["text"], compat: { supportsTools: true },
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: $ctx, contextTokens: $ctx, maxTokens: 4096,
            params: { num_ctx: $ctx, keep_alive: -1, shift: true, truncate: true }
          }]
        }
      }
    },
    agents: {
      defaults: {
        model: { primary: ("ollama/" + $model), fallbacks: [] },
        utilityModel: "",
        skills: [],
        skipBootstrap: true,
        heartbeat: { every: "0m" },
        sandbox: { mode: "off" },
        elevatedDefault: "off"
      }
    },
    tools: {
      profile: "minimal",
      alsoAllow: ["lca"],
      deny: ["presence", "session_status", "gateway", "group:openclaw", "group:fs", "group:runtime", "group:web",
             "group:ui", "group:nodes", "group:messaging", "group:automation", "group:sessions", "group:memory",
             "group:agents", "group:media", "canvas", "transcripts", "tool_search", "tool_describe", "tool_call",
             "bundle-mcp", "node_inference"],
      toolSearch: false,
      exec: { mode: "deny" },
      elevated: { enabled: false },
      web: { search: { enabled: false }, fetch: { enabled: false } },
      agentToAgent: { enabled: false }
    }
  }'
}

# The dashboard model's standing instructions: short, because every word is
# read again on every message on a CPU.
agents_md() {
  cat <<'EOF'
# Dashboard assistant

You run the dashboard of this server, which builds software projects unattended with local models. You can only use the lca_* tools: list projects and their progress, show one project, read its summary, decisions, review, plan, acceptance or log, start a project from a short spec, stop or resume one, and report the server's status, health and models, or restart the agent app or the chat app. You cannot run commands, read other files or browse the web.

Answer briefly. For a long spec, tell the user to paste it with: /project new NAME (then the spec on the next lines), or to upload it in the Projects tab. /lca lists every command.
EOF
}

unit_text() {   # OWNER UID HOME
  local user="$1" uid="$2" home="$3"
  cat <<EOF
# Managed by local-code-agent (openclaw/setup.sh): the browser dashboard,
# run as ${user}. Change it there, not here: setup rewrites this file.
[Unit]
Description=OpenClaw dashboard for local-code-agent (as ${user})
After=network-online.target tailscaled.service ollama.service docker.service user@${uid}.service
Wants=network-online.target user@${uid}.service

[Service]
Type=simple
User=${user}
WorkingDirectory=${home}
EnvironmentFile=${home}/.openclaw/gateway.env
Environment=HOME=${home}
Environment=PATH=${OPENCLAW_DIR}/node/bin:/usr/local/bin:/usr/bin:/bin
Environment=XDG_RUNTIME_DIR=/run/user/${uid}
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus
Environment=OPENCLAW_NO_AUTO_UPDATE=1 DO_NOT_TRACK=1 OPENCLAW_OFFLINE=1 OPENCLAW_DISABLE_BONJOUR=1
Environment=CLAWHUB_DISABLE_TELEMETRY=1 OPENCLAW_SERVICE_REPAIR_POLICY=external NODE_ENV=production
# The tailnet bind needs the Tailscale address at start; it falls back to
# loopback alone without one. Wait for it, a minute at most.
ExecStartPre=/bin/sh -c 'i=0; while [ \$i -lt 60 ]; do tailscale ip -4 >/dev/null 2>&1 && exit 0; i=\$((i+1)); sleep 1; done; exit 0'
ExecStart=${OPENCLAW_BIN} gateway --port ${OPENCLAW_PORT}
Restart=always
RestartSec=5
TimeoutStopSec=60
KillMode=mixed
# No way up from here: nothing it starts can gain privileges (sudo included).
NoNewPrivileges=yes
RestrictSUIDSGID=yes
PrivateTmp=yes
ProtectSystem=full
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
# And no way out: connections to this machine and the tailnet only.
IPAddressDeny=any
IPAddressAllow=localhost 100.64.0.0/10 fd7a:115c:a1e0::/48

[Install]
WantedBy=multi-user.target
EOF
}

cmd_setup() {
  local user uid home pwfile envfile tmp dir
  am_root || die "Setup installs software and a service: run it with sudo (sudo lca dashboard setup)."
  user="$(invoking_user)"
  [[ "${user}" != "root" ]] || die "Run it with sudo from the account that owns the projects, not as root: the dashboard runs as that account."
  uid="$(id -u "${user}")"
  home="$(owner_home "${user}")"
  [[ -n "${AGENT_PROJECTS_DIR}" ]] || die "Project mode is off (AGENT_PROJECTS_DIR is empty in ${ENV_FILE}); the dashboard is for project mode."
  if ! valid_port "${OPENCLAW_PORT}" || [[ "${OPENCLAW_PORT}" == "22" ]]; then
    die "OPENCLAW_PORT='${OPENCLAW_PORT}' is not a usable port."
  fi
  require_cmd curl jq openssl sha256sum tar systemctl loginctl
  tailscale_ip4 >/dev/null || die "There is no Tailscale address: the dashboard listens there and nowhere else. Run: sudo tailscale up"

  tmp="$(mktemp -d)"
  # Expanded now: tmp is local to this function, and the trap runs at exit.
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT
  install_node "${tmp}"
  install_openclaw "${tmp}"

  # Lingering: the owner's own services (each project's runner) run without a
  # login and start at boot, so starting a project needs no root.
  loginctl enable-linger "${user}" || die "Could not enable lingering for ${user}."
  ok "Lingering on for ${user}: projects run as user services, without root"

  dir="${home}/.openclaw"
  install -d -o "${user}" -g "$(id -gn "${user}")" -m 700 "${dir}" "${dir}/workspace"
  pwfile="${home}/.openclaw-dashboard-password"
  if [[ ! -s "${pwfile}" ]]; then
    head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-24 > "${pwfile}"
    ok "A new dashboard password is in ${pwfile} (it is not shown here)"
  fi
  chown "${user}:" "${pwfile}"; chmod 600 "${pwfile}"
  envfile="${dir}/gateway.env"
  ( umask 077; printf 'OPENCLAW_GATEWAY_PASSWORD=%s\n' "$(tr -d '\n' < "${pwfile}")" > "${envfile}" )
  chown "${user}:" "${envfile}"; chmod 600 "${envfile}"

  openclaw_config "${home}" > "${dir}/openclaw.json.new" || die "Could not render the dashboard's config."
  mv -f "${dir}/openclaw.json.new" "${dir}/openclaw.json"
  agents_md > "${dir}/workspace/AGENTS.md"
  chown -R "${user}:" "${dir}"; chmod 600 "${dir}/openclaw.json"
  install -d -o "${user}" -g "$(id -gn "${user}")" -m 700 "${home}/specs"
  ok "Config written: ${dir}/openclaw.json (model $(agent_model_name), window $(agent_model_context), tools: lca only)"

  unit_text "${user}" "${uid}" "${home}" | write_root_file "${OPENCLAW_SERVICE}" 0644 || die "Could not write ${OPENCLAW_SERVICE}."
  set_env_var ENABLE_OPENCLAW true
  set_env_var OPENCLAW_PORT "${OPENCLAW_PORT}"
  load_env
  "${REPO}/netmode.sh" harden >/dev/null || die "Could not add the dashboard's port to the inbound guard (netmode.sh harden)."
  ok "Port ${OPENCLAW_PORT} is in the inbound guard: reachable over Tailscale only"
  systemctl daemon-reload
  systemctl enable openclaw-gateway.service >/dev/null 2>&1
  systemctl restart openclaw-gateway.service || die "The dashboard did not start: journalctl -u openclaw-gateway"
  wait_for_dashboard || die "The dashboard did not answer on port ${OPENCLAW_PORT} within two minutes: journalctl -u openclaw-gateway"
  ok "Dashboard: $(openclaw_dashboard_url)  (password: ${pwfile})"
  info "The first time a browser opens it: enter the password, then approve that browser at $(openclaw_dashboard_url)/lca/panel"
}

wait_for_dashboard() {
  local i ip
  ip="$(tailscale_ip4)" || return 1
  for (( i = 0; i < 60; i++ )); do
    curl -fsS --max-time 3 -o /dev/null "http://${ip}:${OPENCLAW_PORT}/" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

cmd_status() {
  local st url
  st="$(systemctl is-active openclaw-gateway.service 2>/dev/null || true)"
  url="$(openclaw_dashboard_url || true)"
  printf 'Dashboard: %s\nService:   openclaw-gateway.service (%s)\nOpenClaw:  %s\nPassword:  ~/.openclaw-dashboard-password\n' \
    "${url:-off (ENABLE_OPENCLAW=${ENABLE_OPENCLAW})}" "${st:-not installed}" "$(installed_version || echo 'not installed')"
  [[ "${st}" == "active" ]]
}

main() {
  case "${1:-}" in
    setup)   cmd_setup ;;
    url)     openclaw_dashboard_url || die "The dashboard is off, or there is no Tailscale address. Turn it on: sudo lca dashboard setup"; echo ;;
    status)  cmd_status ;;
    restart) LCA_MAY_PROMPT=true; as_root systemctl restart openclaw-gateway.service && ok "Restarted." ;;
    -h|--help|"") usage ;;
    *) usage >&2; die "Unknown: $1" ;;
  esac
}

# Sourceable, so its config can be rendered and checked without installing.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
