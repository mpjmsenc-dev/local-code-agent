# local-code-agent

A fully private, self-hosted AI assistant with the same feel as the Claude app +
Claude Code — running on **your own server**, with **no cloud AI APIs, no API keys,
no telemetry, and no usage quotas**.

| Piece | Role | Like |
|---|---|---|
| [Ollama](https://ollama.com) | Local LLM server (models run on your VM) | the Claude API, but local |
| [Aider](https://aider.chat) | Terminal coding agent (edits code, auto-commits) | Claude Code |
| [Open WebUI](https://github.com/open-webui/open-webui) | Chat web app, works great on a phone | the Claude app |
| [Tailscale](https://tailscale.com) | Private network to your phone/laptop | — |
| qwen2.5-coder | The model family (3b/7b/14b/32b, auto-selected) | the model |

Everything runs on one Ubuntu 24.04 VM — optimized for a DigitalOcean Basic
Droplet (4 vCPU / 8 GB), and equally at home on arm64 or any VMware/Proxmox/KVM VM.

## Quick start (server)

```bash
git clone https://github.com/mpjmsenc-dev/local-code-agent.git
cd local-code-agent
chmod +x *.sh scripts/*.sh
./setup.sh
```

Then verify with `./check-system.sh`. For a zero-terminal DigitalOcean install,
paste `deploy/do-user-data.sh` when creating the droplet — see
[docs/DO.md](docs/DO.md) and the step-by-step [docs/YOUR-TURN.md](docs/YOUR-TURN.md).

## Quick start (phone)

1. `sudo tailscale up` on the server, log in via the printed URL.
2. Install the Tailscale app on your phone, log in to the same account.
3. Open `http://<tailscale-ip>:3000`, create the **first** account (it becomes admin).
4. Lock signups: set `WEBUI_ENABLE_SIGNUP=false` in `.env`, re-run `scripts/install_webui.sh`.

Full walkthrough: [docs/PHONE.md](docs/PHONE.md).

## Headline feature 1: AUTO-TUNE — resize and it adapts

`scripts/tune.sh` runs during setup **and on every boot**. It detects the VM's
RAM and picks the best model + context length, pulls and validates the new model,
reconfigures Ollama, and keeps the old model on disk as a rollback. Resize your
droplet (or change your hypervisor VM's specs) and reboot — that's the whole
upgrade procedure. More vCPUs need no configuration at all: Ollama automatically
uses every core.

| RAM (GiB, detected) | Model | Context |
|---|---|---|
| < 9 | `qwen2.5-coder:3b` | 4096 |
| 9–15 | `qwen2.5-coder:7b` | 8192 |
| 16–23 | `qwen2.5-coder:14b` | 8192 |
| ≥ 24 | `qwen2.5-coder:14b` | 16384 |

`qwen2.5-coder:32b` is deliberately a manual choice for big machines (≥ 32 GB):
`./update-model.sh qwen2.5-coder:32b`. Manual pins set `AUTO_TUNE=false` so a
reboot won't override you. Preview what tune would do: `scripts/tune.sh --dry-run`.

## Headline feature 2: NET SWITCH — the internet kill switch

```bash
sudo ./netmode.sh offline   # AI stack loses ALL internet; phone access keeps working
sudo ./netmode.sh status    # shows mode + proves it with a live probe
sudo ./netmode.sh online    # back to normal
```

Offline mode drops every **new** outbound connection (locally-generated and
docker-forwarded) except loopback and the Tailscale path, and it persists across
reboots. Inference works fully offline — the models are on your disk. Honest
caveat: the encrypted Tailscale tunnel still uses the network as transport;
"offline" means the AI stack can't reach the internet, not that the NIC is dead.

Separately, an **always-on inbound guard** (installed by `setup.sh`, re-applied
every boot) keeps the WebUI and Ollama ports reachable only over loopback and
Tailscale — never from a public IP — without touching SSH. Re-apply or verify it
with `sudo ./netmode.sh harden` / `status`.

## Security model

What "private" means here, precisely — and what it doesn't.

**How your services are kept private**
- **Ollama** binds loopback only (`127.0.0.1:11434` by default). Its API is
  **unauthenticated**, so a non-loopback bind would expose model access to
  anyone who can reach the host — `check-system.sh` warns if you set one.
- **Open WebUI** binds all interfaces (it runs with Docker host networking so
  it can reach loopback Ollama). It is kept private by the **inbound guard**:
  an always-on nftables table (`lca_inbound`) that drops new inbound to the
  WebUI and Ollama ports on every interface **except loopback and
  `tailscale0`**. SSH (22) and all other ports are untouched, so the guard can
  never lock you out. It is re-applied on every boot and whenever WebUI is
  (re)created.
- **Phone access** rides Tailscale — an encrypted, private WireGuard network.
  Nothing is port-forwarded; you reach WebUI at `http://<tailscale-ip>:3000`.
- **No telemetry**: aider has analytics/update checks off; Open WebUI runs with
  `DO_NOT_TRACK`, `SCARF_NO_ANALYTICS`, `ANONYMIZED_TELEMETRY` set.

**The kill switch** (`netmode.sh offline`) adds an egress lockdown: new
outbound connections — locally-generated *and* docker-forwarded — are dropped
except loopback and the Tailscale path. It persists across reboots and is
fail-closed (state is saved before rules apply). Inference keeps working
offline because the models are local.

**Honest limitations**
- The encrypted Tailscale tunnel still uses the network as transport —
  "offline" means the AI stack can't reach the internet, not that the NIC is
  dead.
- The inbound guard is targeted (it blocks the two sensitive ports on
  non-private interfaces), not a full default-drop firewall; it assumes you do
  not expose other services.
- Trust is single-VM: anyone with a shell (or root) on the box has full access.

**Your responsibilities** (see [docs/YOUR-TURN.md](docs/YOUR-TURN.md))
- Create the **first** WebUI account promptly, then set
  `WEBUI_ENABLE_SIGNUP=false` and re-run `scripts/install_webui.sh`.
- **Never** add a cloud/host firewall rule exposing 3000 or 11434 to the
  internet, and keep `OLLAMA_HOST` on loopback.
- Verify the posture any time with `./check-system.sh` and
  `sudo ./netmode.sh status`. On DigitalOcean, the **Recovery Console** is the
  unbrick path if you ever lock yourself out (see [docs/DO.md](docs/DO.md)).

## Daily usage: aider (the coding agent)

```bash
cd ~/my-project                          # YOUR project, any git repo
/opt/local-code-agent/run-agent.sh       # starts aider on the local model
```

Inside aider: `/add file.py` to add files, then ask for changes in plain English —
it edits and auto-commits. `/undo` reverts, `/help` lists commands. Extra
arguments pass straight through, e.g. `run-agent.sh --no-auto-commits`.

## Scripts

| Script | Purpose |
|---|---|
| `setup.sh` | Install everything (idempotent, unattended-safe) |
| `run-agent.sh` | Start aider in the current directory |
| `webui.sh` | `start\|stop\|restart\|status\|logs` for Open WebUI |
| `netmode.sh` | `offline\|online\|status` kill switch + `harden` inbound guard |
| `check-system.sh` | Full health check with colored summary |
| `update-model.sh` | Safely switch models (`--list`, `--remove-old`) |
| `backup.sh` / `restore.sh` | Backup/restore WebUI data + `.env` + model list |
| `uninstall.sh` | Remove the stack (`--yes`, `--keep-data`); keeps Docker/Tailscale/repo |
| `scripts/tune.sh` | Auto-tune (also `--dry-run`) |

## `.env` reference

Created from `.env.example` on first run. All keys:

| Key | Default | Meaning |
|---|---|---|
| `AUTO_TUNE` | `true` | Re-tune model/context to RAM on every boot; `false` = manual pin |
| `MODEL_NAME` | `qwen2.5-coder:7b` | Model used by aider + WebUI (managed by auto-tune) |
| `OLLAMA_HOST` | `127.0.0.1:11434` | Ollama listen address (keep loopback-only) |
| `OLLAMA_CONTEXT_LENGTH` | `8192` | Context window in tokens |
| `OLLAMA_KEEP_ALIVE` | `30m` | How long the model stays in RAM after last use |
| `AIDER_VERSION` | *(empty)* | Pin aider-chat version; empty = latest |
| `PYTHON_BIN` | `python3` | Interpreter for the venv |
| `VENV_NAME` | `.venv` | Venv directory name (inside this repo) |
| `SKIP_DOCKER` | `false` | Skip Docker (disables WebUI) |
| `ENABLE_WEBUI` | `true` | Install/run Open WebUI |
| `WEBUI_PORT` | `3000` | WebUI port (reached via Tailscale) |
| `WEBUI_CONTAINER` | `open-webui` | Container name |
| `WEBUI_ENABLE_SIGNUP` | `true` | Set `false` after creating your account |

## Repository tree

```
local-code-agent/
├── README.md · LICENSE · .env.example · .gitignore
├── setup.sh · run-agent.sh · webui.sh · netmode.sh
├── backup.sh · restore.sh · check-system.sh · update-model.sh · uninstall.sh
├── scripts/
│   ├── lib.sh · tune.sh
│   ├── install_dependencies.sh · install_git.sh · install_docker.sh
│   ├── install_python.sh · install_ollama.sh · install_webui.sh
│   └── install_tailscale.sh
├── deploy/do-user-data.sh      # paste-ready DigitalOcean first-boot installer
├── config/aider.conf.yml · config/ollama.env
├── tests/                      # unit tests (lib, tune ladder, netmode ruleset)
├── .github/workflows/ci.yml    # CI: shellcheck · unit tests · nft/systemd checks
└── docs/  INSTALL · PHONE · DO · MIGRATE · YOUR-TURN · TROUBLESHOOTING · FAQ
```

## Honest expectations vs Claude

Local 3b–14b models are **not** frontier models. Expect useful but simpler code
edits, more misfires on complex refactors, and slower responses (CPU inference is
a comfortable reading pace, not instant; the base 4 vCPU / 8 GB droplet auto-tunes
to the 3b model, with 7b from ~12 GB and 14b from 16 GB). What you get in
exchange: total privacy, zero per-token cost, no quotas, and offline operation.
The stack scales with hardware — resize to more RAM and auto-tune upgrades the
model automatically; 32 GB+ unlocks `qwen2.5-coder:32b` as a manual choice.

## Docs

[INSTALL](docs/INSTALL.md) · [YOUR-TURN (start here!)](docs/YOUR-TURN.md) ·
[DO](docs/DO.md) · [PHONE](docs/PHONE.md) · [MIGRATE](docs/MIGRATE.md) ·
[TROUBLESHOOTING](docs/TROUBLESHOOTING.md) · [FAQ](docs/FAQ.md)

## License

[MIT](LICENSE)
