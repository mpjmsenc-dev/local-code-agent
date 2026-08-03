# PHONE.md — using your private AI from a phone

You reach your server privately over Tailscale — an encrypted network between the
server and your phone, nothing to port-forward. The WebUI port is kept private by
an always-on nftables inbound guard (installed by `setup.sh`) that blocks ports
3000 and 11434 on every interface except loopback and Tailscale, while leaving SSH
open. **Never add a firewall rule that exposes ports 3000 or 11434 publicly** —
that would defeat the guard. (Verify with `sudo ./netmode.sh status`.)

## 1. Connect the server to Tailscale (once)

On the server (SSH or the DigitalOcean web console):

```bash
sudo tailscale up
```

It prints a login URL. Open it (on any device), sign in (Google/GitHub/etc. work),
and the server joins your private network. Get its private IP:

```bash
tailscale ip -4
```

That `100.x.y.z` address is your permanent phone URL base.

## 2. Install the Tailscale app on the phone (once)

1. Install **Tailscale** from the App Store / Play Store.
2. Log in with the **same account** you used for the server.
3. Flip the VPN toggle on. You should see your server in the machine list.

## 3. Open the chat app and create YOUR account

On the phone browser, go to:

```
http://<tailscale-ip>:3000
```

(e.g. `http://100.101.102.103:3000` — use your own `tailscale ip -4` result.)

Or skip the typing: run `lca chat` on the server and it prints the address as a
**QR code**. Point your phone's camera at it and tap the link. The address is
printed above the code too, in case your scanner dislikes a terminal QR.

Tap **Sign up** and create the **FIRST** account — the first account automatically
becomes the **admin**.

## 4. Lock signups (important)

After your account exists, close the door behind you. On the server:

```bash
cd /opt/local-code-agent
sed -i 's/^WEBUI_ENABLE_SIGNUP=.*/WEBUI_ENABLE_SIGNUP=false/' .env
sudo lca apply
```

`lca apply` is the line that closes the door: a running container keeps the
setting it was started with, so editing `.env` on its own changes nothing. It
re-creates the container with the new setting — your account and chats live in
a docker volume and survive. To confirm it took:

```bash
lca check             # must say "signups are closed"
```

## 5. Make it feel like an app

In the phone browser menu choose **Add to Home Screen**. Open WebUI is a PWA —
launched from the home screen icon it looks and feels like the Claude app:
full-screen chat, streaming responses, chat history, model picker.

## What the chat already knows about your server

`setup.sh` gives the chat a system prompt so it answers as *your* assistant
rather than a generic model: keep it short (you are reading on a phone, at a few
tokens per second), prefer real commands, say "I don't know" instead of inventing
a flag, and know that this box is driven by the `lca` command. Ask *"how do I
take a backup right now?"* and you get `lca backup`, not a lecture about `tar`.
The empty-chat screen also offers four starter questions aimed at code and
servers, in place of Open WebUI's stock ones about vocabulary exams and the
Roman Empire.

The same prompt is used by `lca ask` in the terminal, so both doors lead to the
same assistant.

**Changing it later:** these two settings come from the environment, so editing
the repo and running `sudo lca apply` takes effect. The one
exception is a setting you have already changed **inside the WebUI**: Open WebUI
stores that in its own database, and a stored value always wins over the
environment. So if you edit the assistant's system prompt in **Admin Panel →
Settings**, that is where it lives from then on, and re-running the installer
will not overwrite it.

## What the chat can and cannot do

The chat is a **text box with no filesystem**. It cannot create files, run
commands, or see your project — so "build me a whole app" is the one request it
genuinely cannot fulfil, no matter which model you run. Asked anyway, it will
say so and point you at the command that can.

That command is bare **`lca`** (aider), in a terminal, inside your project
directory:

```bash
cd ~/my-project && lca
```

aider reads and writes real files and makes commits, on the same local model.
Note `lca ask` is *not* it — that is one-shot text, like the chat.

Expect from the chat: questions about the box, short complete files you can
copy, explaining an error, reviewing a snippet you paste. On the base 8 GB
droplet it runs the 3b model, which is genuinely small — it will not
autonomously produce a multi-file project, and pushing it to try tends to
produce confident nonsense rather than code. More RAM buys a bigger model
(see the ladder above), but the filesystem limit is about the door, not the
model.

## Running the coding agent from the phone

The terminal agent (aider) runs over SSH:

- **iOS/Android SSH app** (Termius, Blink, JuiceSSH...): connect to the server's
  Tailscale IP as usual, then:

  ```bash
  cd ~/your-project
  /opt/local-code-agent/run-agent.sh
  ```

- **No SSH app?** The DigitalOcean web console (Droplet → Access → Launch Droplet
  Console) works from a phone browser too.

The internet kill switch is also phone-friendly — over that same SSH session:

```bash
sudo /opt/local-code-agent/netmode.sh offline    # or online / status
```

(Tailscale SSH keeps working in offline mode by design.)

## Speed expectations

- On the base 4 vCPU / 8 GB droplet, auto-tune runs **qwen2.5-coder:3b** (8 GiB
  detected falls in the `< 9 GiB` rung) — the fastest, most modest model.
  The bigger **7b** kicks in from **9 GiB detected** upward (a ~12–16 GB VM).
  A comfortable reading pace, slower than Claude.
- For scale: on a 16 GiB CPU-only x86_64 machine, 3b measured **12 tokens/second**
  and 7b **6**. Your droplet has a different CPU, so treat those as the shape of
  the difference (roughly 2× per halving of size) rather than a promise — run
  `lca speed` for your own number, which takes about a minute.
- The small model still behaves like *your* assistant rather than a generic
  one — 3b was checked against the same system prompt and answers "how do I
  take a backup?" with `lca backup`, not a lecture about `tar`.
- Resize the droplet to 16 GB and reboot → auto-tune upgrades to the 14b model
  automatically (smarter, slower per token). No reconfiguration needed.
- The first message after a quiet period is slower — the model reloads into RAM.
  How much slower depends on whether the file is still in the operating
  system's disk cache: measured on one machine, **0.3 seconds** when the model
  was already resident, ~20 seconds warm, and **228 seconds** from genuinely
  cold. If that is the thing that annoys you most (it usually is, because you
  hit it every time you pick up your phone), set `OLLAMA_KEEP_ALIVE=-1` in
  `.env` and run `sudo lca apply`: the model then stays resident permanently.
  The cost is that its RAM is never released.

  Editing `.env` alone is not enough — Ollama keeps the settings it was started
  with. `lca apply` applies it immediately, and a reboot now applies it too.
  Until it is applied, `lca check` says so: `config drift: your .env differs
  from what Ollama is actually running`.
- **After a reboot the model is loaded for you.** Nothing used to do this —
  auto-tune only loads the model when it is *changing*, and then restarts
  Ollama straight afterwards, dropping it again. The boot service now kicks off
  a warm-up in the background, so the load happens while you are still
  unlocking your phone rather than while you wait for a reply. It is
  best-effort and never delays boot; if you beat it to the first message you
  are no worse off than before.
- `lca speed` on the server measures all of this and tells you what is limiting
  it.

## If the page won't load

In order: is the phone's Tailscale toggle on? → does `./check-system.sh` on the
server pass the WebUI checks? → `./webui.sh status` → see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).
