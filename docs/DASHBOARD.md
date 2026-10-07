# The dashboard: project mode from a browser

One page, on this machine's Tailscale address, behind a password: start a
project from a pasted or uploaded spec, follow every project live, stop and
resume them, read what they decided and what the review found; and see the
server's health, models, CPU, RAM and disk. It is [OpenClaw](https://github.com/openclaw/openclaw)
(MIT), cut down to that one job.

```bash
sudo lca dashboard setup     # once: installs it, writes its config, turns it on
lca dashboard url            # http://<tailscale-ip>:18789
cat ~/.openclaw-dashboard-password
```

## Using it

1. Open the address from any device on your tailnet and enter the password.
2. The first time a browser connects, OpenClaw asks for it to be approved
   ("pairing required"). Open `<address>/lca/panel` in the same browser,
   enter the password, press **Approve the browser waiting for approval**,
   and reload the dashboard. Once per browser (a private window is a new one
   every time).
3. In the chat:

| type | does |
|---|---|
| `/project new NAME` and, on the next lines, the whole spec | saves it as `~/specs/NAME.md` and builds it in `~/projects/NAME`, unattended |
| `/project save NAME` + spec, then `/project start NAME` | the same in two steps, to check what arrived first (characters, lines, sha256) |
| `/project list` | every project: status, steps done of total, the step it is on, elapsed time, queue position |
| `/project status NAME` | one project's plan, step by step |
| `/project stop NAME` · `/project resume NAME` | stop it (it can be resumed), carry on from where it stopped |
| `/project delete NAME`, then `/project delete NAME NAME` | delete a stopped or finished project: `~/projects/NAME`, `~/specs/NAME.md`, its runner unit and any leftover sandbox; the second form, with the name typed again, is the confirmation. No undo |
| `/project summary` · `decisions` · `review` · `plan` · `acceptance` · `log` `NAME` | its files: the summary, DECISIONS.md, REVIEW.md, PLAN.md, ACCEPTANCE.md, the run log |
| `/server status` · `/server health` · `/server models` | CPU, RAM, disk, models, containers, what runs; `lca check --quick` (no generation probe, which could evict a running project's model); the models and which is loaded |
| `/server restart agent` · `/server restart chat` | the only two things that can be restarted from here |
| `/lca` | this list |

These run without the model: they answer in a second even while a project
keeps the model busy, and a pasted spec arrives exactly as pasted (measured:
41,229 characters with literal `\n`, tabs, Unicode and code fences, saved
byte-identical). Plain questions ("how far is the CRM?") go to the model,
which can use the same operations as tools; it answers when the model is free.

4. The **Projects** tab (in the sidebar, or `<address>/lca/panel`) shows every
   project live, refreshed every five seconds, with a form to paste or upload
   a spec file and start it, Stop and Resume, and each project's files. A
   stopped or finished project also has **Delete…**, which asks you to type
   its name before it removes anything.

One project runs at a time; the others queue and start by themselves.
Projects run as you, as user services, without root; they need nothing from
your session and resume after a reboot.

## What it can and cannot do

Everything below is OpenClaw's own config (`~/.openclaw/openclaw.json`,
written by `sudo lca dashboard setup`) and its unit, not a prompt, and
`lca check` reads the config back and fails if any of it changed.

- **One model, local, already loaded.** Only the Ollama provider is loaded,
  with the agent's model by the same name and window, and Ollama's shift and
  truncate defaults, so the dashboard shares the projects' runner and never
  evicts it. No hosted provider is loaded; there is no fallback.
- **One plugin's tools.** `plugins.allow` is `ollama` and `lca`; every other
  plugin (browser, canvas, file transfer, hosted providers, channels) stays
  unloaded. The model's tools are the lca plugin's ten (`/tools verbose` lists
  them): no shell, no file access, no browser, no web search or fetch. The
  host terminal in the dashboard is off.
- **No skills, no installs.** No bundled or community skills, ClawHub off, no
  skill workshop, uploads off.
- **No channels.** No Telegram, WhatsApp or anything else; heartbeat and
  scheduled jobs off; no update checks or telemetry.
- **Reachable only over Tailscale.** It binds the Tailscale address and
  loopback, port 18789 is in the inbound guard, and it needs the password.
  Plain HTTP inside WireGuard: the tailnet has no HTTPS certificates turned
  on, which is also why the Projects tab asks for the password itself.
- **No way up, no way out.** It runs as you under systemd
  (`openclaw-gateway.service`) with `NoNewPrivileges` (nothing it starts can
  use sudo) and may only open connections to this machine and the tailnet.

What the plugin runs, each with fixed arguments and never through a shell:
`scripts/agent-project.sh` (start with `--autonomy answerer`, stop, resume,
status), `lca check`, a restart of the two named containers (the agent app
and the chat app; neither applies a setting, see `lca apply` for that), and
`openclaw devices` to approve a browser. Deleting a project is yours alone:
it is a command and a button, never one of the model's tools. A project name becomes a directory
and a file name only: lower case, letters, digits and dashes.

## Settings

`ENABLE_OPENCLAW`, `OPENCLAW_PORT` in `.env`; the password in
`~/.openclaw-dashboard-password` (mode 600: change it there, then
`sudo lca dashboard setup`). OpenClaw and Node are pinned and checksummed in
`openclaw/setup.sh` and installed root-owned under `/opt/openclaw`.
