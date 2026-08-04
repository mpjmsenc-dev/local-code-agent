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
| qwen2.5-coder | The model family (3b/7b/14b, auto-selected by RAM) | the model |

Everything runs on one Ubuntu 24.04 VM — optimized for a DigitalOcean Basic
Droplet (4 vCPU / 8 GB), and equally at home on arm64 or any VMware/Proxmox/KVM VM.

## Quick start (server)

One command on a fresh Ubuntu 24.04 box:

```bash
curl -fsSL https://raw.githubusercontent.com/mpjmsenc-dev/local-code-agent/main/install.sh | bash
```

It installs git, clones to `/opt/local-code-agent`, and runs `setup.sh`. Piping
into a shell means running code you have not read, so if you would rather look
first (it is short, and this is the better habit):

```bash
curl -fsSL https://raw.githubusercontent.com/mpjmsenc-dev/local-code-agent/main/install.sh -o install.sh
less install.sh && bash install.sh
```

Overrides: `LCA_DIR` (install location), `LCA_BRANCH`, `LCA_REPO_URL` (your
fork), `LCA_RUN_SETUP=false` (clone only). Re-running updates the checkout.

Or do it by hand:

```bash
git clone https://github.com/mpjmsenc-dev/local-code-agent.git
cd local-code-agent
chmod +x *.sh scripts/*.sh bin/*
./setup.sh
```

Then verify with `lca check`. For a zero-terminal DigitalOcean install,
paste `deploy/do-user-data.sh` when creating the droplet — see
[docs/DO.md](docs/DO.md) and the step-by-step [docs/YOUR-TURN.md](docs/YOUR-TURN.md).

## Quick start (phone)

1. `sudo tailscale up` on the server, log in via the printed URL.
2. Install the Tailscale app on your phone, log in to the same account.
3. Open `http://<tailscale-ip>:3000` — or run `lca chat` on the server to
   print the exact address. Create the **first** account (it becomes admin).
   Your model is already selected, so you can just start typing.
4. Lock signups: set `WEBUI_ENABLE_SIGNUP=false` in `.env`, then `sudo lca apply`.

Full walkthrough: [docs/PHONE.md](docs/PHONE.md).

## Headline feature 1: AUTO-TUNE — resize and it adapts

`scripts/tune.sh` runs during setup **and on every boot**. It detects the VM's
RAM and picks the best model + context length, pulls and validates the new model,
reconfigures Ollama, brings the chat app onto the new model too (its model is
fixed when the container is created, so that means re-creating it), and keeps
the old model on disk as a rollback. Resize your
droplet (or change your hypervisor VM's specs) and reboot — that's the whole
upgrade procedure. More vCPUs need no configuration at all: Ollama automatically
uses every core.

| RAM (GiB, detected) | Model | Context |
|---|---|---|
| < 9 | `qwen2.5-coder:3b` | 4096 |
| 9–15 | `qwen2.5-coder:7b` | 8192 |
| 16–23 | `qwen2.5-coder:14b` | 8192 |
| ≥ 24 | `qwen2.5-coder:14b` | 16384 |

**Want a different model?** Set `MODEL_FAMILY` in `.env` and auto-tune picks the
largest size of *that* family your RAM allows — one line changes the model
everywhere, and a resize still re-tunes it:

| `MODEL_FAMILY` | small / mid / big |
|---|---|
| `qwen2.5-coder` *(default)* | 3b / 7b / 14b |
| `qwen3` | 4b / 8b / 14b |
| `deepseek-coder-v2` | 16b / 16b / 16b |
| `llama3.1` | 8b / 8b / 8b — 70b and 405b stay a manual choice |
| `codellama` | 7b / 13b / 13b — 34b stays a manual choice |

An unrecognised value falls back to the default instead of failing a pull.

`qwen2.5-coder:32b` is deliberately a manual choice for big machines (≥ 32 GB):
`lca model qwen2.5-coder:32b`. Manual pins set `AUTO_TUNE=false` so a
reboot won't override you. Preview what tune would do: `lca tune --dry-run`.

## Headline feature 2: NET SWITCH — the internet kill switch

```bash
sudo lca offline             # AI stack loses ALL internet; phone access keeps working
sudo lca status               # shows mode + proves it with a live probe
sudo lca online               # back to normal
```

Offline mode drops every **new** outbound connection (locally-generated and
docker-forwarded) except loopback and the Tailscale path, and it persists across
reboots. Inference works fully offline — the models are on your disk. Honest
caveat: the encrypted Tailscale tunnel still uses the network as transport;
"offline" means the AI stack can't reach the internet, not that the NIC is dead.

Separately, an **always-on inbound guard** (installed by `setup.sh`, re-applied
every boot) keeps the WebUI and Ollama ports reachable only over loopback and
Tailscale — never from a public IP — without touching SSH. Re-apply or verify it
with `sudo lca harden` / `sudo lca status`; `harden` also (re)installs the boot
service, so one command closes the ports for good rather than until the next
reboot.

## Updating

```bash
lca update --check      # what would change? (touches nothing)
lca update              # back up → pull → re-run setup → self-test
```

The backup happens **first**, on purpose: the update refreshes OS packages,
aider, Ollama and possibly the model, so the restore point has to predate all of
it. If the self-test fails afterwards, `lca restore` puts you back. Your `.env`
is untracked, so your settings survive updates untouched.

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
- **No telemetry, and no other outbound chatter**: aider has analytics/update
  checks off; Open WebUI runs with `DO_NOT_TRACK`, `SCARF_NO_ANALYTICS` and
  `ANONYMIZED_TELEMETRY` set, plus `ENABLE_OPENAI_API=false` and
  `ENABLE_VERSION_UPDATE_CHECK=false` so it neither probes `api.openai.com`
  nor asks GitHub whether it is out of date; and Ollama runs with
  `OLLAMA_NO_CLOUD=1`, which turns off its remote inference and web search —
  both of which are ON by default and talk to `ollama.com`.

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
- **Offline mode still permits DNS (UDP/TCP port 53) and STUN (UDP 3478) to any
  host, the WireGuard port 41641, and — link-local only — DHCP (UDP 67/68/547)
  and ICMPv6 neighbour discovery, so the VM can keep its lease and its IPv6
  neighbours.** It also accepts any packet carrying tailscaled's own fwmark
  (0x80000), whatever the destination — that is how tailscaled's control and
  data packets bypass its own routing. Setting that mark needs root, so this
  belongs to the last point below rather than being a separate way out.
  Tailscale needs them: without DNS,
  `tailscaled` cannot re-resolve its coordination server after a reboot, and
  you would lose the private access that this mode exists to preserve. So
  "offline" means *the AI stack cannot reach the web* (HTTP/HTTPS and
  everything else is dropped), not that literally every packet is blocked — a
  process that deliberately spoke over port 53 could still get data out. These
  exceptions are deliberate; they are not scoped further precisely because a
  narrower rule risks cutting Tailscale and stranding you on a remote VM.
- Trust is single-VM: anyone with a shell (or root) on the box has full access.
- **The install trusts four upstreams, as root.** `install.sh` is fetched with
  `curl | bash` (its header offers a download-and-read path instead), and setup
  then runs the vendors' own installers the way each vendor documents:
  `curl -fsSL https://ollama.com/install.sh | sh` and the same shape for
  Tailscale, plus Docker's apt key and repository. Nothing here is pinned by
  hash. That is the normal way these three are installed and this project does
  not improve on it — but "private" describes where your *data* goes, not who
  you are trusting to put the software there.
- **Two components float rather than pin.** The chat app runs the
  `ghcr.io/open-webui/open-webui:main` tag, and `AIDER_VERSION` is empty by
  default, meaning the latest aider from PyPI. So `lca update` — which
  re-creates the container and re-runs pip — can bring in whatever upstream
  published since. Pin aider with `AIDER_VERSION=` in `.env` if you would
  rather choose your moment; the WebUI tag is not currently configurable.

**Your responsibilities** (see [docs/YOUR-TURN.md](docs/YOUR-TURN.md))
- Create the **first** WebUI account promptly, then set
  `WEBUI_ENABLE_SIGNUP=false` and run `sudo lca apply`.
- **Never** add a cloud/host firewall rule exposing 3000 or 11434 to the
  internet, and keep `OLLAMA_HOST` on loopback.
- Verify the posture any time with `lca check` and
  `sudo lca status`. On DigitalOcean, the **Recovery Console** is the
  unbrick path if you ever lock yourself out (see [docs/DO.md](docs/DO.md)).

## Daily usage: aider (the coding agent)

```bash
cd ~/my-project     # YOUR project, any git repo
lca                 # starts aider on the local model, right here
```

`setup.sh` puts `lca` on your PATH. It is one short front door to everything:

| Command | Does |
|---|---|
| `lca` | start the coding agent in the current directory |
| `lca ask "…"` | one-shot answer in the terminal — no session, no browser |
| `lca chat` | phone setup: the chat app's address **and** the `ssh://` address, both as QR codes |
| `lca check` / `lca test` | health check / live end-to-end self-test (`lca check --quick` skips the ~1-minute model probe) |
| `lca apply` | make the running system match your `.env` edits (`--dry-run` previews) |
| `lca logs` | recent logs from Ollama, the chat app and the installer |
| `lca speed` | measure tokens/second and explain what limits it |
| `lca update` | back up, update, re-run setup, verify |
| `lca offline` / `lca online` / `lca status` | internet kill switch, and what it is doing (needs sudo) |
| `lca harden` | re-close ports 3000/11434 — now, and again on every boot (needs sudo) |
| `lca model <name>` | switch models (`--list` what's installed, `--list-recommended` what fits this machine's RAM) |
| `lca tune` | re-pick the model for this machine's RAM (auto-tune) |
| `lca backup` / `lca restore` | take a backup now / put one back |
| `lca webui <cmd>` | the chat app: `start`, `stop`, `restart`, `status`, `url`, `logs` |

`lca <command> --help` explains any of them — and only explains it. That is
tested: `lca test --help` used to run the whole acceptance suite, and
`lca harden --help` used to apply the firewall.

Quick answers without leaving what you are doing:

```bash
lca ask "how do I find the 10 largest files under /var?"
lca ask "why is setup.sh failing?"        # names a local file -> it is included
lca ask -f netmode.sh "what does this script do?"
lca ask -c "now show me that as a one-liner"   # follows on from the last answer
lca ask -m qwen2.5-coder:3b "..."         # try another model, just this once
```

Because it is *your* machine's AI, it can read your machine's own output:

```bash
lca check | lca ask "what is the most important thing to fix, and the command?"
lca logs  | lca ask "why did this fail?"
```

That is not a party trick — on a box whose Docker daemon was down, the first
one picked Docker out of a 24-line health report as the root cause and gave
`sudo systemctl start docker`. Nothing left the machine to do it.

`lca help` lists them all. Everything after the command is passed through, so
`lca --no-auto-commits` reaches aider and `lca model X --remove-old` reaches
update-model.sh. The full script paths still work if you prefer them.

Inside aider: `/add file.py` to add files, then ask for changes in plain English —
it edits and auto-commits. `/undo` reverts, `/help` lists commands. Extra
arguments pass straight through, e.g. `run-agent.sh --no-auto-commits`.

**Output quality is tuned for you.** `run-agent.sh` picks the edit format from
the model size (models ≤4B rewrite whole files, which they get right far more
often than search/replace diffs; bigger models use cheaper diffs) and scales
aider's repo map to your context window so it never crowds out the code being
edited. Override with `LCA_EDIT_FORMAT` in `.env`.

## Scripts

| Script | Purpose |
|---|---|
| `install.sh` | One-command bootstrap: installs git, clones, runs `setup.sh` |
| `setup.sh` | Install everything (idempotent, unattended-safe) |
| `update.sh` | Update safely: backup → new code → re-run setup → self-test (`--check` previews) |
| `run-agent.sh` | Start aider in the current directory |
| `webui.sh` | `start\|stop\|restart\|status\|url\|logs` for Open WebUI |
| `netmode.sh` | `offline\|online\|status` kill switch + `harden` inbound guard |
| `check-system.sh` | Full health check with colored summary (`--quick` skips the real-generation probe) |
| `update-model.sh` | Safely switch models (`--list`, `--remove-old`) |
| `backup.sh` / `restore.sh` | Backup/restore WebUI data + `.env` + model list (keeps newest `BACKUP_KEEP`; `--install-timer` for daily) |
| `uninstall.sh` | Remove the stack (`--yes`, `--keep-data`); keeps Docker/Tailscale/repo |
| `scripts/tune.sh` | Auto-tune (also `--dry-run`) |
| `scripts/selftest.sh` | Live end-to-end acceptance test (`make smoke`): model + aider + WebUI round-trip |
| `scripts/apply.sh` | `lca apply` — re-apply `.env` to the things that hold their own copy |
| `scripts/prompt-bench.sh` | Measure the assistant's system prompt against the real model (see CONTRIBUTING) |

## `.env` reference

Created from `.env.example` on first run. All keys:

| Key | Default | Meaning |
|---|---|---|
| `AUTO_TUNE` | `true` | Re-tune model/context to RAM on every boot; `false` = manual pin |
| `MODEL_NAME` | `qwen2.5-coder:7b` | Model used by aider + WebUI (managed by auto-tune) |
| `MODEL_FAMILY` | `qwen2.5-coder` | Family auto-tune picks from: `qwen3`, `deepseek-coder-v2`, `llama3.1`, `codellama` |
| `OLLAMA_HOST` | `127.0.0.1:11434` | Ollama listen address (keep loopback-only) |
| `OLLAMA_CONTEXT_LENGTH` | `8192` | Context window in tokens |
| `OLLAMA_KEEP_ALIVE` | `30m` | How long the model stays in RAM after last use |
| `AIDER_VERSION` | *(empty)* | Pin aider-chat version; empty = latest |
| `AIDER_CONVENTIONS` | `true` | Load `config/CONVENTIONS.md` read-only each aider session (tighter edits; costs a little context) |
| `LCA_EDIT_FORMAT` | `auto` | How aider asks for edits. `auto` = `whole` for ≤4B models, `diff` above; or force `whole`/`diff`/`udiff` |
| `LCA_ASK_TOKENS` | `512` | Longest answer `lca ask` will generate. On CPU an uncapped reply can run for minutes |
| `PYTHON_BIN` | `python3` | Interpreter for the venv |
| `VENV_NAME` | `.venv` | Venv directory name (inside this repo) |
| `SKIP_TAILSCALE` | `false` | Skip Tailscale. Phone access is then over a private network you provide; the inbound guard still limits the WebUI port to loopback and `tailscale0` |
| `SKIP_DOCKER` | `false` | Skip Docker (disables WebUI) |
| `ENABLE_WEBUI` | `true` | Install/run Open WebUI |
| `WEBUI_PORT` | `3000` | WebUI port (reached via Tailscale) |
| `WEBUI_CONTAINER` | `open-webui` | Container name |
| `WEBUI_NAME` | `local-code-agent` | Title shown in the chat app on your phone |
| `WEBUI_ENABLE_SIGNUP` | `true` | Set `false` after creating your account |
| `BACKUP_KEEP` | `7` | How many backups `backup.sh` keeps; older ones are pruned (`0` = keep all) |
| `BACKUP_SCHEDULE` | `"*-*-* 03:30:00"` | When the backup timer fires (systemd `OnCalendar`) — **keep the quotes**; e.g. `"daily"`, `"weekly"` |

## Repository tree

```
local-code-agent/
├── README.md · CONTRIBUTING.md · LICENSE · .env.example · .gitignore
├── install.sh                  # one-command installer (curl | bash)
├── Makefile                    # make gates/lint/test/hooks — the local dev loop
├── bin/lca                     # the short command installed on PATH
├── setup.sh · update.sh · run-agent.sh · webui.sh · netmode.sh
├── backup.sh · restore.sh · check-system.sh · update-model.sh · uninstall.sh
├── scripts/
│   ├── lib.sh · tune.sh · selftest.sh · apply.sh · ask.sh
│   ├── logs.sh · speed.sh · motd.sh · prompt-bench.sh
│   ├── install_dependencies.sh · install_git.sh · install_docker.sh
│   ├── install_python.sh · install_ollama.sh · install_webui.sh
│   └── install_tailscale.sh
├── deploy/do-user-data.sh      # paste-ready DigitalOcean first-boot installer
├── config/aider.conf.yml · config/ollama.env · config/CONVENTIONS.md
├── tests/                      # unit tests (lib, tune ladder, netmode ruleset)
├── .githooks/pre-push          # runs `make gates` before every push (make hooks)
├── .github/workflows/ci.yml    # CI: lint · unit · system · minimal-base · e2e · webui
└── docs/  INSTALL · PHONE · DO · MIGRATE · YOUR-TURN · TROUBLESHOOTING · FAQ ·
            BACKUPS · PERFORMANCE
```

## Performance & GPU

Inference speed depends on hardware:
- **CPU (default, e.g. a Basic droplet):** works everywhere, but it's a reading
  pace, not instant — expect a few tokens/second, slower for bigger models. This
  is the fully-supported, tested path.
- **GPU (optional, much faster):** if the host has a supported NVIDIA GPU with
  drivers installed, **Ollama uses it automatically — no config change needed.**
  Options: a DigitalOcean **GPU droplet**, a cloud GPU instance, or a local
  hypervisor with **GPU passthrough**. `check-system.sh` reports whether a GPU
  was detected.

`lca speed` measures tokens/second, reports whether your model is actually on
the GPU or the CPU (`ollama ps`'s PROCESSOR column), and names what is limiting
it — a driver can be present and Ollama still fall back to CPU. See
**[docs/PERFORMANCE.md](docs/PERFORMANCE.md)** for what moves the needle in
order, and **[docs/GPU.md](docs/GPU.md)** for adding a card, choosing a model
that fits its VRAM, and proving it is really being used.

Note: CI exercises the CPU path on standard runners (there are no GPU runners),
so the GPU path is documented and detected but not automatically E2E-tested —
verify it on your GPU host with `lca check` after setup.

## Honest expectations vs Claude

Local 3b–14b models are **not** frontier models. Expect useful but simpler code
edits, more misfires on complex refactors, and slower responses (CPU inference is
a comfortable reading pace, not instant; the base 4 vCPU / 8 GB droplet auto-tunes
to the 3b model, with 7b from ~12 GB and 14b from 16 GB). What you get in
exchange: total privacy, zero per-token cost, no quotas, and offline operation.
The stack scales with hardware — resize to more RAM and auto-tune upgrades the
model automatically; 32 GB+ unlocks `qwen2.5-coder:32b` as a manual choice.

### What "builds an app" actually looks like on 3b

Measured, five identical runs on the base droplet's rung — *"create budget.py
with `add_expense(amount, category)` and `total_by_category()`, and
test_budget.py with unittest tests for both"*:

| | Result |
|---|---|
| Both files written and applied | **5 / 5** |
| Malformed edits aider had to reject | **0 / 5** |
| Time per run | ~1 minute |
| The tests it wrote passed first time | **0 / 5** |

The last row is the honest one, and the failure is worth seeing: `add_expense`
accumulated a running total per category while `total_by_category` called
`sum()` on it, so one of the two tests it wrote caught its own bug. A one-line
fix, and the test that finds it comes free in the same run.

So: it reliably produces a working shape and rarely one-shots correct logic.
Keep the tests it writes and run them — on 3b they are the deliverable that
shows you the one line to change.

Asking 3b to fix it does not work: handed the exact traceback, four runs out
of four re-emitted the same file unchanged. The same follow-up on **7b** fixed
it in **3 of 4**. That is the concrete thing more RAM buys here — and it is the
opposite of the chat's handover behaviour, where a bigger model measures
[identical](docs/PHONE.md). Full numbers, including why `--auto-test` is not
the shortcut it looks like, are in
[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

If you expect to type one sentence and get a finished app, no local model on an
8 GB droplet will do that.

## Docs

[INSTALL](docs/INSTALL.md) · [YOUR-TURN (start here!)](docs/YOUR-TURN.md) ·
[DO](docs/DO.md) · [PHONE](docs/PHONE.md) · [MIGRATE](docs/MIGRATE.md) ·
[TROUBLESHOOTING](docs/TROUBLESHOOTING.md) · [FAQ](docs/FAQ.md) ·
[PERFORMANCE](docs/PERFORMANCE.md) · [GPU](docs/GPU.md) · [BACKUPS](docs/BACKUPS.md) · [CONTRIBUTING (the AI-assisted dev loop)](CONTRIBUTING.md)

## License

[MIT](LICENSE)
