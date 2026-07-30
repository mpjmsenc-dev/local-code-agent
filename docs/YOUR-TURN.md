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
2. Type this and press Enter:

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
2. Tap **Sign up**, enter a name/email/password — this **first account becomes the
   admin**. You're now chatting with your private AI.
3. Lock signups so nobody else can register. Back in the droplet console:

   ```bash
   cd /opt/local-code-agent
   sed -i 's/^WEBUI_ENABLE_SIGNUP=.*/WEBUI_ENABLE_SIGNUP=false/' .env
   ./scripts/install_webui.sh
   ```

4. Optional but nice: in the phone browser menu, tap **Add to Home Screen** —
   now it opens like a normal app.

## Step 5 — Try the internet kill switch

In the droplet console (or an SSH app), type each line and read what it says:

```bash
sudo /opt/local-code-agent/netmode.sh offline
sudo /opt/local-code-agent/netmode.sh status
sudo /opt/local-code-agent/netmode.sh online
```

While offline: chat on your phone keeps working (the AI is local!), but the server
can't reach the internet at all. `status` proves it with a live probe.

## Step 6 — You are finished when…

- [ ] `tail`ing the log showed `SETUP COMPLETE — local-code-agent is ready.`
- [ ] Your phone's Tailscale app shows the server in its machine list.
- [ ] `http://100.x.y.z:3000` opens the chat and you can send a message and get a reply.
- [ ] Signups are locked (step 4.3 ran without errors).
- [ ] `netmode.sh status` showed "Internet reachable — as expected in online mode."
- [ ] Bonus: in the console, `cd /opt/local-code-agent && ./check-system.sh` ends
      green ("All hard checks passed" or better).
- [ ] Bonus: prove it end-to-end with `./scripts/selftest.sh` (or `make smoke`) —
      it asks your model for a real answer and runs a real aider round-trip, then
      prints `SELF-TEST PASSED`. This is the "does it actually work on MY box?"
      check, and it changes nothing.

**If stuck:**

- Install log problems → [TROUBLESHOOTING.md](TROUBLESHOOTING.md) ("user-data" section).
- Phone can't open the chat → [PHONE.md](PHONE.md) bottom section.
- Locked yourself out with netmode → [DO.md](DO.md) "Recovery Console".
- Anything else → run `./check-system.sh` in `/opt/local-code-agent` and read its
  messages; each failure names the fix.
