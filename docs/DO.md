# DO.md — everything DigitalOcean

## Creating the droplet

1. In the DigitalOcean control panel click **Create → Droplets**.
2. **Region**: pick the one nearest you (latency to the chat UI).
3. **Image**: Ubuntu **24.04 (LTS) x64**.
4. **Size**: *Basic* plan → *Regular* CPU → **4 vCPUs / 8 GB RAM** (~50 GB disk).
   Bigger works too — auto-tune will use it (see the resize section).
5. Open **Advanced Options** and check **Add Initialization scripts (free)**
   — paste the entire contents of [`deploy/do-user-data.sh`](../deploy/do-user-data.sh)
   into the text box. (If you forked the repo, edit the `REPO_URL=` line first.)
6. Add your SSH key (recommended) or a root password, then **Create Droplet**.

The droplet installs everything by itself on first boot (~20–30 minutes,
mostly model download).

## Watching the install

Open the droplet page → **Access** → **Launch Droplet Console** and log in.
The login banner answers this on its own, before you type anything:

```
 local-code-agent  still installing — nothing works yet (log updated 3s ago)
   Currently            Downloading the model
   Watch it             tail -f /var/log/local-code-agent-setup.log
```

It reprints on every login, so logging in again is the quickest way to check.
To watch it live instead:

```bash
tail -f /var/log/local-code-agent-setup.log
```

The install is finished when you see the line:

```
SETUP COMPLETE — local-code-agent is ready.
```

…and the banner switches to `local-code-agent  ready`.

Then continue with [YOUR-TURN.md](YOUR-TURN.md) step 3 (Tailscale login).

## Resizing — the "make it smarter" button

Auto-tune means a resize IS the upgrade procedure:

1. Droplet page → **Power** → turn the droplet **off**.
2. **Resize** → choose **CPU and RAM only** (keeps your disk and data; this
   direction is also reversible, so you can size back down later).
3. Pick the new size (e.g. 16 GB RAM) and apply.
4. **Power on**. On boot, `local-code-agent-tune.service` detects the new RAM,
   downloads the matching model (e.g. 14b), validates it, reconfigures Ollama —
   zero manual steps. Sizing back down works the same way: tune downgrades the
   model instead of letting the bigger one OOM.

Progress after a resize-boot: `journalctl -u local-code-agent-tune.service -f`.

## Billing truths (read before leaving a droplet around)

- **Powered-off droplets still bill.** You pay for the reserved CPU/RAM/disk even
  when the droplet is off. To pause spending: take a **snapshot**, **destroy** the
  droplet, and recreate from the snapshot later (snapshot storage costs cents/GB).
- Billing is **per second** (with a monthly cap per droplet).
- As of July 2026, new accounts get a **$5 / 90-day credit** — the old $200 trial
  ended July 15, 2026. A 4 vCPU / 8 GB Basic droplet costs real money within days,
  so don't count on trial credit to run this long-term.

## Recovery Console — the netmode unbrick path

`netmode.sh offline` is designed to never cut the Tailscale path. But if you ever
lock yourself out anyway (broken Tailscale login, experimenting with the rules),
you do NOT need SSH: droplet page → **Access** → **Launch Recovery/Droplet
Console** gives you a local terminal that no firewall rule can block. From there:

```bash
sudo /opt/local-code-agent/netmode.sh online
```

## Firewall

Open WebUI runs with Docker host networking and so binds port 3000 on **all**
interfaces, including the droplet's public IP (Ollama's 11434 stays on
loopback). To make the "reached only over Tailscale/loopback" promise real,
`setup.sh` installs an **always-on nftables inbound guard** (managed by
`netmode.sh`, re-applied every boot) that **drops new inbound connections to
3000 and 11434 on every interface except loopback and `tailscale0`**. SSH
(port 22) and all other ports are untouched, so the guard can never lock you
out. Check it any time with `sudo ./netmode.sh status` (look for "inbound
guard ... LOADED"); re-apply with `sudo ./netmode.sh harden`.

With that guard in place there is **nothing to open**: reach WebUI over
Tailscale. **Never** add a DO cloud firewall rule (or any other rule)
exposing 3000 or 11434 to the internet — that would defeat the guard and make
your private AI public. A DO cloud firewall that *only* allows inbound 22 (and
nothing else from the public internet) is a fine optional extra layer.

## Snapshots and migration

DO snapshots restore only into DigitalOcean — they **cannot be downloaded**. To
move to your own hardware/hypervisor later, this repository + `backup.sh` IS the
migration path: see [MIGRATE.md](MIGRATE.md).
