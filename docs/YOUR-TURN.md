# YOUR-TURN.md — the ONLY manual steps (phone-friendly, zero terminal experience needed)

Everything else is automated. These six steps are the only things a human must do,
in this order. Copy-paste blocks are exact; button names are exact.

---

## Step 1 — Create the droplet (5 minutes, in a browser)

1. Sign up / log in at digitalocean.com and click the green **Create** button → **Droplets**.
2. Choose a **Region** near you.
3. Under **Choose an image** pick **Ubuntu 24.04 (LTS) x64**.
4. Under **Choose Size**: click **Basic**, CPU options **Regular**, and select the
   **4 vCPUs / 8 GB RAM** option.
5. Under **Choose Authentication Method**: easiest is **Password** — type a strong
   root password and save it somewhere safe.
6. Click **Advanced Options** (near the bottom) and tick
   **Add Initialization scripts (free)**. A text box appears.
7. Open this repository's file `deploy/do-user-data.sh`, copy **the whole file**,
   and paste it into that text box.
8. Click **Create Droplet**. Done — the server now installs everything itself.

## Step 2 — Wait ~20–30 minutes, then confirm it finished

1. On the droplet's page, click **Access** in the left menu → **Launch Droplet
   Console**. A black terminal window opens in your browser; log in as `root`
   with your password if asked.

   **The moment you log in, the server tells you where it is up to.** Above the
   prompt you'll see one of these:

   ```
    local-code-agent  still installing — nothing works yet (log updated 3s ago)
      Currently            Downloading the model
      Watch it             tail -f /var/log/local-code-agent-setup.log
   ```

   ```
    local-code-agent  ready   ·   model qwen2.5-coder:7b
      Chat on your phone   http://100.x.y.z:3000
      Write code here      cd ~/my-project && lca   (edits real files)
      Ask right here       lca ask "why is this box slow?"
      All commands         lca help
   ```

   That middle line is the product; the two around it cannot touch a file.
   Step 6 below is where you use it.

   If it says **ready**, skip straight to Step 3. If it says **still
   installing**, log out and come back later, or watch it live as below. It
   reprints on every login, so you can keep checking by logging in again.

2. To watch it live, type this and press Enter:

   ```bash
   tail -f /var/log/local-code-agent-setup.log
   ```

3. You'll see the install scrolling by. **It is done when this exact line appears:**

   ```
   SETUP COMPLETE — local-code-agent is ready.
   ```

   If instead you see this line, the install finished but something essential
   failed (usually the model download on a flaky connection) — don't continue;
   jump to "If stuck":

   ```
   SETUP FINISHED WITH ERRORS — run /opt/local-code-agent/check-system.sh and see docs/TROUBLESHOOTING.md
   ```

4. Press `Ctrl` + `C` to stop watching the log.

   (Neither line appears after 40 minutes? See "If stuck" at the bottom.)

## Step 3 — Connect Tailscale (server + phone)

1. Still in the droplet console, type:

   ```bash
   sudo tailscale up
   ```

2. It prints a link like `https://login.tailscale.com/a/xxxxxxxx`. Open that link
   on your phone or computer and sign in (Google or GitHub is fine). The console
   then says `Success.`
3. Get your private address — type:

   ```bash
   tailscale ip -4
   ```

   Write down the `100.x.y.z` number it prints. That's your server's private address.
4. On your phone, install the **Tailscale** app from the App Store / Play Store,
   log in with the **same account**, and switch the VPN toggle **on**.

## Step 4 — Create your chat account, then lock the door

1. On your phone's browser open: `http://100.x.y.z:3000` (your number from step 3).

   Easier: type `lca chat` in the droplet console. It prints a QR code — point
   your phone's camera at the screen and tap the link, no typing. It prints a
   second QR too, the `ssh://` address: scan that one now as well, because the
   chat will eventually hand you a command to run in a terminal and this is
   how you get one from the phone.
2. Tap **Sign up**, enter a name/email/password — this **first account becomes the
   admin**. You're now chatting with your private AI.
3. Lock signups so nobody else can register. Back in the droplet console:

   ```bash
   cd /opt/local-code-agent
   sed -i 's/^WEBUI_ENABLE_SIGNUP=.*/WEBUI_ENABLE_SIGNUP=false/' .env
   sudo lca apply
   ```

   **Both lines matter.** Editing `.env` does not change a chat app that is
   already running — `lca apply` is what actually applies it. If you only do
   the first, `lca check` keeps reporting `signups are OPEN` until it is
   really closed.

4. Optional but nice: in the phone browser menu, tap **Add to Home Screen** —
   now it opens like a normal app.

## Step 5 — Try the internet kill switch

In the droplet console (or an SSH app), type each line and read what it says:

```bash
sudo lca offline
sudo lca status
sudo lca online
```

While offline: chat on your phone keeps working (the AI is local!), but the server
can't reach the internet at all. `status` proves it with a live probe.

## Step 6 — Write your first code (this is the actual product)

Everything up to here got you a **chat**. The chat cannot create, read or edit
a single file — it is a text box, and a banner in it says so. If you stop at
step 5 you will eventually ask it to build something, get a confident tutorial
it cannot finish, and conclude the thing cannot code. That has happened to a
real user, and it is why this step exists.

The part that writes files is the bare word `lca` — that is aider, on the same
private model. In the droplet console or over SSH:

```bash
mkdir -p ~/hello && cd ~/hello
git init                       # aider commits each edit; this is what makes that possible
printf 'def add(a, b):\n    return a + b\n' > calc.py
git add -A && git commit -m "start"

lca                            # the coding agent, in THIS directory
```

Then type a request and press Enter — for example:

```
add a subtract(a, b) function to calc.py
```

Watch it edit the real file. When it is done, `/quit`, and then **read what it
actually did**:

```bash
git diff HEAD~1
```

That last command is not optional politeness. A small local model sometimes
changes code you never mentioned — measured on `qwen2.5-coder:7b`, asked for
two specific edits it made both correctly *and deleted an unrelated function*.
Because aider commits every edit, `git diff HEAD~1` shows you exactly that, and
`git revert <sha>` undoes it. Get in the habit now, on a two-line file, rather
than later on something you care about. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#review-every-edit--local-models-can-make-unrequested-changes).

Expect it to be slower than a cloud assistant and to need a second try on
anything complex — [README](../README.md#honest-expectations-vs-claude) is
blunt about what a 3b–14b model does and does not do well. What you have is a
coding assistant that is entirely yours, with no quota and no data leaving the
box.

## Step 7 — You are finished when…

- [ ] `tail`ing the log showed `SETUP COMPLETE — local-code-agent is ready.`
- [ ] Logging in again greets you with `local-code-agent  ready`.
- [ ] Your phone's Tailscale app shows the server in its machine list.
- [ ] `http://100.x.y.z:3000` opens the chat and you can send a message and get a reply.
- [ ] Signups are locked (step 4.3 ran without errors).
- [ ] `sudo lca status` showed "Internet reachable — as expected in online mode."
- [ ] **You ran `lca` in a project directory and it edited a real file** (step 6),
      and you read `git diff HEAD~1` afterwards. This is the one that proves you
      have a coding assistant rather than a chat window.
- [ ] Bonus: in the console, run `lca check` — it ends green ("All hard checks
      passed" or better). `lca help` lists everything else.
- [ ] Bonus: ask it something without leaving the terminal —
      `lca ask "how much disk is left?"`, then `lca ask -c "and how do I free some?"`
      to follow on. If anything looks wrong, `lca logs | lca ask "why did this fail?"`
      lets your own AI read its own logs. `lca speed` answers "why is it slow?"
- [ ] Bonus: prove it end-to-end with `lca test` —
      it asks your model for a real answer and runs a real aider round-trip, then
      prints `SELF-TEST PASSED`. This is the "does it actually work on MY box?"
      check, and it changes nothing.

**If stuck:**

- Install log problems → [TROUBLESHOOTING.md](TROUBLESHOOTING.md) ("user-data" section).
- Phone can't open the chat → [PHONE.md](PHONE.md) bottom section.
- Locked yourself out with netmode → [DO.md](DO.md) "Recovery Console".
- Anything else → run `lca check` and read its messages; each failure names the
  fix. (`lca` is installed by setup; the full paths under `/opt/local-code-agent`
  still work if you prefer them.)
