# TROUBLESHOOTING.md — symptom → fix

Run `lca check` first: it pinpoints most of these automatically.

Two commands worth knowing before you read any further:

```bash
lca check | lca ask "what is the most important thing to fix, and the command?"
lca logs  | lca ask "why did this fail?"
```

Neither is a gimmick. The model is already on the machine, it sees the same
output you do, and it is usually faster than finding the right section below —
on a box whose Docker daemon was down, the first command picked Docker out of a
24-line health report and answered `sudo systemctl start docker`.

`lca logs` on its own shows Ollama, the chat app and the installer in one place.
`lca speed` answers "why is it slow?" specifically.

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
to another port and run `sudo lca apply` — which re-renders the drop-in AND
re-creates the chat app container, so the phone follows Ollama to the new port
instead of talking to one nothing listens on.

## Port 3000 (WebUI) already in use

`scripts/install_webui.sh` now refuses to start if another process already
holds `WEBUI_PORT` — it would otherwise crash-loop while the squatter answered
the port, looking deceptively healthy. See what's on it:

```bash
sudo ss -tlnp | grep :3000
```

Then either stop that service, or pick a free port: set `WEBUI_PORT` in `.env`
to something else and run `sudo lca apply`. If `lca webui status`
or `check-system.sh` reports the container "CRASH-LOOPING (restarting)", this
port conflict (or a bad `.env` value) is the usual cause — check
`lca webui logs`.

## Out of memory / model gets killed / responses never finish

The model + context don't fit in RAM. In order:

1. `lca tune` — if RAM shrank (resize down), this downgrades the model
   to the right rung of the ladder.
2. Still tight? Lower `OLLAMA_CONTEXT_LENGTH` in `.env` (e.g. 8192 → 4096) and
   run `sudo lca apply` to re-render + restart.
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
   in `.env` and run `sudo lca apply`.
3. A very large file can't fit whole — point aider at the specific
   function/region instead of adding the entire file.

## aider: "model not found" or connection errors

aider reaches Ollama via litellm, which needs two things `run-agent.sh` sets for
you: the `ollama_chat/` model prefix and `OLLAMA_API_BASE`. So: always start
aider through `run-agent.sh`, not bare `aider`. If it still fails:
`lca check` (is the API up? is the model pulled?), and make sure `.env`'s
`MODEL_NAME` appears in `ollama list`.

## docker: "permission denied ... /var/run/docker.sock"

Your user was added to the `docker` group during setup, but group membership only
applies to **new** logins. Log out and back in (or `newgrp docker`). Still broken:
`sudo usermod -aG docker $USER`, then re-login.

## WebUI unreachable from the phone

Check in this order:

1. Container: `lca webui status` (and `lca webui logs` for errors).
2. Tailscale: phone app toggle ON? `tailscale status` on the server logged in?
   Using the right IP (`tailscale ip -4`) and port (3000)?
3. Netmode: `sudo lca status` — offline mode does NOT block Tailscale,
   but a half-applied experiment might; `sudo lca online` to reset.
4. Inbound guard: `sudo lca status` also shows the always-on inbound
   guard. **By design it allows the WebUI port only over loopback and
   `tailscale0`** — so reaching WebUI by the server's public or LAN IP
   (without Tailscale) is *supposed* to fail. Always go through the Tailscale
   IP. If `status` reports the guard is NOT loaded, re-apply it with
   `sudo lca harden`.

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
sudo lca status
sudo lca online              # if you want internet back
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

## I asked the chat to build my app and it wrote a tutorial / invented a tool call

The chat has no filesystem. Asked to build a project it cannot build, a small
model does not refuse — it starts a confident multi-file tutorial it has no way
to finish, and truncates part-way through a file. Earlier versions also emitted
a fabricated tool call (`{"name": "build_expense_tracker", ...}`) or fell back
on *"the constraints of my design and training"*, which is not the real reason.

The real reason is that this door has no filesystem, and the fix is to use the
one that does:

```bash
mkdir -p ~/my-project && cd ~/my-project && lca
```

That is aider, on the same local model, and it reads and writes real files.
`lca ask` is **not** it — that is one-shot text, exactly like the chat.

The chat should now say this itself, unprompted, on any request to build,
create, make or add something. If yours does not, it is running the system
prompt it was created with:

```bash
lca check          # look for: chat app config drift: SYSTEM_PROMPT
cd /opt/local-code-agent && git pull
sudo lca apply     # re-creates the container; chats and accounts survive
```

The container keeps a copy of the prompt from the moment it was created, so
pulling a better one is not enough on its own — see the table below.

**How to tell which of the three it is**, quickest first:

1. `lca check` names `chat app config drift: SYSTEM_PROMPT` → the container is
   older than the prompt. `sudo lca apply` and you are done.
2. It happens in a **long** chat but not a brand-new one → far less likely
   than it used to be. Re-measured on Ollama 0.32.5, an overflowing chat drops
   the old TURNS and keeps the system prompt — 4/4 still answered correctly
   with the history trimmed from ~5,400 tokens to 559. See "Why does it forget
   earlier messages" in [FAQ.md](FAQ.md) for the numbers. Worth ruling out by
   starting a new chat, but do 1 first.
3. It happens in a brand-new chat on a current container → something is
   advertising tools to the model. Check the model's **Function Calling**
   setting and any enabled Tools in Open WebUI's workspace; a tool schema in
   the request beats an instruction in the prompt.

Measured on `qwen2.5-coder:3b` — the rung an 8 GB box runs, and the one the
report came from — with the current prompt and no tools attached: eight
samples of "build me an income and expense tracker", four in a fresh chat and
four behind ~6,000 tokens of history. **Zero produced a tool call**, six of
eight opened with the handover, two wrote a tutorial. So the prompt does its
job when it reaches the model tool-free; a tool call means either it did not
reach the model (1 and 2 above) or something else was in the request (3).

`scripts/prompt-bench.sh` counts tool calls now, so a prompt change can be
judged against this failure rather than only against the tutorial.

## aider wrote the files, but the code does not work

That is the expected shape of this stack on a small model, not a fault to
diagnose. Measured on `qwen2.5-coder:3b`, five identical runs of a two-file
request (a module plus unittest tests for it): **5/5** wrote and applied both
files with no malformed edits, in about a minute each — and **0/5** produced
tests that passed first time. In every run the tests it wrote caught its own
bug, which is the useful part.

Run the tests. On 3b they are the deliverable that shows you the one line to
change:

```bash
python3 -m unittest            # or however your project runs its tests
```

**Handing the error back does not work on 3b.** Given the exact traceback and
both files, four runs out of four re-emitted `budget.py` byte-identical — no
fix, no error, "Applied edit to budget.py", 14-37 seconds each. The same
follow-up on **7b** fixed it in **3 of 4** (100-287 seconds). Correctness is
the one thing a bigger rung genuinely buys here, which is worth saying plainly
because it is the opposite of the chat's handover behaviour, where 3b and 7b
measure identical ([PHONE.md](PHONE.md)).

**`--auto-test` is not the shortcut it looks like.** aider can run your tests
itself and feed failures back — `lca --auto-test --test-cmd 'python3 -m
unittest discover -q'`. Measured on the same task, three runs on 3b: all three
ended with failing tests, all three exhausted aider's three-reflection limit,
and each took **~6.3 minutes** against **~1 minute** for the plain run. On a
CPU box every reflection is another full generation, and a small model tends to
circle the same wrong fix.

So on the base droplet's rung: ask for one file at a time, keep the tests, and
expect to fix small logic yourself. From ~12 GB of RAM auto-tune moves you to
7b and the follow-up loop starts working — at roughly three minutes a round.

## I changed a setting in .env and nothing happened

Some settings are read fresh every run (`MODEL_NAME`, `LCA_ASK_TOKENS`,
`BACKUP_KEEP`). Others are *applied* to something long-lived — a systemd
drop-in or a docker container — and keep working with the values they were
started with until that thing is rebuilt. `lca check` reports both cases:

**The short answer: run `sudo lca apply`.** It re-applies `.env` to everything
that holds its own copy of a setting, touches only what has actually drifted,
and is safe to run whenever you are unsure. `lca apply --dry-run` says what it
would do without doing it.

The long answer, if you want to know what it is doing:

| Setting | Applied by | If you only edit `.env` |
|---|---|---|
| `OLLAMA_HOST`, `OLLAMA_CONTEXT_LENGTH`, `OLLAMA_KEEP_ALIVE` | the ollama drop-in | `lca check` says `config drift`. Fixed by `lca apply`, `sudo scripts/tune.sh`, or a reboot |
| `WEBUI_PORT`, `MODEL_NAME` (as preselected), `WEBUI_ENABLE_SIGNUP`, `OLLAMA_HOST`, `WEBUI_NAME` | the WebUI container | `lca check` says `chat app config drift`. Fixed by `lca apply` |
| the assistant's system prompt and starter questions | the WebUI container | same — and these come from the **repo**, not `.env`, so a `git pull` that improves the prompt still needs `sudo lca apply` |
| `BACKUP_SCHEDULE` | the systemd timer | Fixed by `lca apply` or `sudo lca backup --install-timer` |
| `WEBUI_PORT`, `OLLAMA_HOST` (the port half) | the inbound guard's nftables ruleset | `lca check` says the guard `does NOT cover` a port. Fixed by `lca apply` or `sudo lca harden` |

That second row was the longest-lived hole in this table: nothing compared the
system prompt, so `lca apply` answered *"already matches .env"* after a repo
update that changed it, and the chat kept its old behaviour with nothing
anywhere saying so.

The last row was the worst one, because the thing left behind was a firewall.
The guard was only ever re-applied as a side effect of re-creating the chat app
container — so with the chat app switched off, moving `OLLAMA_HOST` to a new
port left the guard dropping the old one while the **unauthenticated** Ollama
API answered on the new one, on every interface, and `lca apply` said
*"Everything already matches .env"*.

## Ollama settings drifted / drop-in edited by hand

`/etc/systemd/system/ollama.service.d/local-code-agent.conf` is **rendered** from
`.env` + `config/ollama.env` — manual edits are overwritten on the next
`scripts/tune.sh` or `scripts/install_ollama.sh` run. Change the source values in
`.env` / `config/ollama.env` instead, then `sudo lca apply` applies them.
`check-system.sh` warns when the configured model drifts from the tune
recommendation.

## A script died mid-install (network blip, Ctrl-C, reboot)

Just run `./setup.sh` again. Every installer is idempotent — finished pieces are
detected and reused; only the missing pieces are (re)done.

This is exactly what the login banner is telling you when it says:

```
 local-code-agent  the install stopped before it finished (nothing written to the log for 3 h)
   Stopped at           Installing Docker and Open WebUI
   Finish it            sudo /opt/local-code-agent/setup.sh
```

## The login banner says something different from what I expect

It is deliberately driven by the live system, not by the install log, because
an interrupted install often leaves a perfectly working stack behind. So:

| Banner | What it means |
|---|---|
| `still installing` | The install log was written to in the last 15 minutes and has not reached a verdict. |
| `the install stopped before it finished` | The log went quiet mid-install **and** nothing is serving. Re-run it: `cd /opt/local-code-agent && sudo ./setup.sh`. |
| `the install did NOT finish` | The log reached an explicit failure verdict. Start with `lca logs setup`. |
| `installed, but the model engine is not running` | Ollama is not answering. `lca check`, then `lca logs ollama`. |
| `engine running, but model … is NOT downloaded` | Ollama answers, but the model in `.env` is not on disk — so nothing can reply yet. It is a download, not a fault: `sudo /opt/local-code-agent/setup.sh` finishes it. |
| `ready · model …` | Ollama answered **and** the model is there. This wins over anything the log says. |

One extra line can appear under `ready`, and it is the one worth reading:

| Row | What it means |
|---|---|
| `Chat is OUT OF DATE  ·  it answers with an older assistant — sudo lca apply` | The chat app is healthy and reachable, but it is running the assistant instructions it was **created** with. Those are baked into the container, so `git pull` does not reach a running one and nothing restarts it. Run `sudo lca apply`. |

That row is why `ready` is not the whole story. The assistant decides what the
chat *does* — whether it hands a build request to `lca` or tries to walk you
through it, whether it emits a tool call it cannot make — and every
infrastructural check on the box passes either way. If you are seeing odd chat
behaviour and this row is showing, apply it before debugging anything else.
The row appears only on a positive answer: no `jq`, no container, or a docker
that will not answer within two seconds all print nothing rather than guess.

Not seeing a banner at all? `lca check` reports whether it is installed, and
`sudo /opt/local-code-agent/scripts/motd.sh --install` puts it back. Systems
without `/etc/update-motd.d` (some containers and minimal images) get no
banner — everything else works exactly the same.
