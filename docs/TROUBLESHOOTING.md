# TROUBLESHOOTING.md — symptom → fix

Run `lca check` first: it pinpoints most of these automatically.

Two commands worth knowing before you read any further:

```bash
lca logs                              # Ollama, the chat app and the installer, in one place
lca logs | lca ask "why did this fail?"   # let your own model read them for you
```

That second one is not a gimmick — the model is already on the machine, it sees
the same output you do, and it is usually faster than finding the right section
below. `lca speed` answers "why is it slow?" specifically.

## apt is locked ("Could not get lock /var/lib/dpkg/lock-frontend")

Another apt process (often Ubuntu's automatic security updates on a fresh boot)
is running. Wait a few minutes and retry. See who holds it:

```bash
sudo lsof /var/lib/dpkg/lock-frontend
```

If a stale process truly hangs: `sudo kill <pid>`, then `sudo dpkg --configure -a`
and re-run `./setup.sh`.

## Port 11434 already in use (Ollama won't start)

Something else is bound to the Ollama port. Diagnose:

```bash
sudo ss -tlnp | grep 11434
```

Usually it's a manually-started `ollama serve` fighting the systemd service —
kill the manual one (`sudo pkill -f "ollama serve"`) and
`sudo systemctl restart ollama`. Alternatively change `OLLAMA_HOST` in `.env`
to another port and re-run `scripts/install_ollama.sh`.

## Port 3000 (WebUI) already in use

`scripts/install_webui.sh` now refuses to start if another process already
holds `WEBUI_PORT` — it would otherwise crash-loop while the squatter answered
the port, looking deceptively healthy. See what's on it:

```bash
sudo ss -tlnp | grep :3000
```

Then either stop that service, or pick a free port: set `WEBUI_PORT` in `.env`
to something else and re-run `scripts/install_webui.sh`. If `./webui.sh status`
or `check-system.sh` reports the container "CRASH-LOOPING (restarting)", this
port conflict (or a bad `.env` value) is the usual cause — check
`./webui.sh logs`.

## Out of memory / model gets killed / responses never finish

The model + context don't fit in RAM. In order:

1. `scripts/tune.sh` — if RAM shrank (resize down), this downgrades the model
   to the right rung of the ladder.
2. Still tight? Lower `OLLAMA_CONTEXT_LENGTH` in `.env` (e.g. 8192 → 4096) and
   re-run `scripts/install_ollama.sh` to re-render + restart.
3. Check nothing else eats RAM: `free -h`, `docker stats`.

## "It's so slow"

CPU inference (no GPU) is a reading pace, not instant — the base 8 GB droplet
auto-tunes to the small 3b model; 7b (from ~12 GB) and 14b (from 16 GB) are
smarter but slower per token. First response after idle is slower (model loads
into RAM; `OLLAMA_KEEP_ALIVE` controls how long it stays warm). Want
faster/smarter? Resize to more RAM/CPU — auto-tune handles the rest.

## The model ignores earlier context or instructions in a long session

Everything the model sees — system prompt, chat history, open files, aider's
repo map, and its own reply — shares one fixed context window
(`OLLAMA_CONTEXT_LENGTH`, set by auto-tune per the RAM ladder). `run-agent.sh`
tells aider the real window size (via a generated model-metadata file), so aider
trims the *oldest* history to stay within budget rather than letting Ollama
silently drop it. If replies start losing the thread or getting cut off:

1. Keep the working set small — aider's `/clear` drops old context; close files
   you're done with. Less history leaves more window for the answer.
2. For a bigger window, add RAM and let auto-tune raise the rung (8 GB → 4096,
   ~12 GB → 8192, 16 GB → 8192, 24 GB+ → 16384), or set `OLLAMA_CONTEXT_LENGTH`
   in `.env` and re-run `scripts/install_ollama.sh`.
3. A very large file can't fit whole — point aider at the specific
   function/region instead of adding the entire file.

## aider: "model not found" or connection errors

aider reaches Ollama via litellm, which needs two things `run-agent.sh` sets for
you: the `ollama_chat/` model prefix and `OLLAMA_API_BASE`. So: always start
aider through `run-agent.sh`, not bare `aider`. If it still fails:
`./check-system.sh` (is the API up? is the model pulled?), and make sure `.env`'s
`MODEL_NAME` appears in `ollama list`.

## docker: "permission denied ... /var/run/docker.sock"

Your user was added to the `docker` group during setup, but group membership only
applies to **new** logins. Log out and back in (or `newgrp docker`). Still broken:
`sudo usermod -aG docker $USER`, then re-login.

## WebUI unreachable from the phone

Check in this order:

1. Container: `./webui.sh status` (and `./webui.sh logs` for errors).
2. Tailscale: phone app toggle ON? `tailscale status` on the server logged in?
   Using the right IP (`tailscale ip -4`) and port (3000)?
3. Netmode: `sudo ./netmode.sh status` — offline mode does NOT block Tailscale,
   but a half-applied experiment might; `sudo ./netmode.sh online` to reset.
4. Inbound guard: `sudo ./netmode.sh status` also shows the always-on inbound
   guard. **By design it allows the WebUI port only over loopback and
   `tailscale0`** — so reaching WebUI by the server's public or LAN IP
   (without Tailscale) is *supposed* to fail. Always go through the Tailscale
   IP. If `status` reports the guard is NOT loaded, re-apply it with
   `sudo ./netmode.sh harden`.

### I actually want direct LAN access (advanced, reduces privacy)

The guard blocks the WebUI/Ollama ports on every interface except loopback and
Tailscale on purpose. If you deliberately want to reach WebUI over a trusted
LAN without Tailscale, the guard is what's stopping you — that is the private-
only guarantee working. Only lift it if you understand the exposure (and never
on a host with a public IP): `sudo nft delete table inet lca_inbound` (returns
on the next boot/`harden` unless you also stop running `harden`).

## "No internet" on the server

**First check the kill switch** — this is expected behavior when offline mode is on:

```bash
sudo ./netmode.sh status
sudo ./netmode.sh online     # if you want internet back
```

Only if mode is `online` and the probe still fails is it a real network problem
(DNS, DO networking, your hypervisor's NAT...).

## Where is the first-boot install log? (DigitalOcean)

```bash
tail -f /var/log/local-code-agent-setup.log
```

If it doesn't exist, the user-data script never ran — most likely the paste into
"Add Initialization scripts" was missed when creating the droplet. Recover by
running the same script manually as root: copy `deploy/do-user-data.sh` onto the
droplet and `sudo bash do-user-data.sh`.

## Ollama settings drifted / drop-in edited by hand

`/etc/systemd/system/ollama.service.d/local-code-agent.conf` is **rendered** from
`.env` + `config/ollama.env` — manual edits are overwritten on the next
`scripts/tune.sh` or `scripts/install_ollama.sh` run. Change the source values in
`.env` / `config/ollama.env` instead, then `scripts/install_ollama.sh` applies them.
`check-system.sh` warns when the configured model drifts from the tune
recommendation.

## A script died mid-install (network blip, Ctrl-C, reboot)

Just run `./setup.sh` again. Every installer is idempotent — finished pieces are
detected and reused; only the missing pieces are (re)done.
