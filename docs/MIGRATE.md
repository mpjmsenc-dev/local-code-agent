# MIGRATE.md — moving from DigitalOcean to your own hypervisor

DigitalOcean snapshots **cannot be downloaded**, so a snapshot is not a migration
path off DO. This repository is: everything on the droplet was installed by these
scripts, and everything personal fits in one `backup.sh` tarball. Auto-tune then
adapts the stack to the new VM's specs automatically — the new machine does not
need to match the droplet's size.

## On the droplet (source)

```bash
cd /opt/local-code-agent
lca backup
```

This writes `backups/local-code-agent-backup-<timestamp>.tar.gz` containing the
Open WebUI data volume (your account + all chats), your `.env`, and the list of
installed models (names only — model blobs re-download on the new machine).

`backup.sh` prints the exact path it wrote. Copy **that one** to your computer
(run this on your computer, not the droplet):

```bash
scp root@<droplet-ip>:/opt/local-code-agent/backups/local-code-agent-backup-20260101-120000.tar.gz .
```

Use the filename `backup.sh` printed rather than a `*` glob: retention keeps
the newest `BACKUP_KEEP` (default 7), and each one contains the whole WebUI
volume, so a glob quietly drags every old backup across the wire when you
wanted the one you just took.

## On the new VM (target)

1. Create a fresh **Ubuntu 24.04 Server** VM in VMware / Proxmox / KVM
   (sizing guidance in [INSTALL.md](INSTALL.md); arm64 is fine).
2. Install the stack:

   ```bash
   git clone https://github.com/mpjmsenc-dev/local-code-agent.git /opt/local-code-agent
   cd /opt/local-code-agent
   chmod +x *.sh scripts/*.sh bin/*
   ./setup.sh
   ```

3. Copy the backup tarball onto the VM (run on your computer):

   ```bash
   scp local-code-agent-backup-*.tar.gz root@<vm-ip>:/opt/local-code-agent/backups/
   ```

4. Restore your data:

   ```bash
   cd /opt/local-code-agent
   lca restore
   ```

   This restores `.env` and the WebUI volume, recreates the container, re-pulls
   your models, and finishes by running `lca apply` so the restored settings are
   actually in effect rather than merely on disk.

   Then re-pick the model for *this* machine:

   ```bash
   sudo lca tune
   ```

   The backup carries the **droplet's** model and context length, which is the
   whole point of this document being about moving to different hardware.
   Auto-tune would fix it on the next boot anyway — this just means you are not
   running the small droplet's model on a big new VM until then. Picking a
   different model than the droplet had is the feature, not a bug: it matches
   the new VM's RAM.

5. Join the new machine to your Tailscale network:

   ```bash
   sudo tailscale up
   ```

   Your phone setup doesn't change — only the Tailscale IP is new
   (`tailscale ip -4`). Update the home-screen bookmark, done.

6. Verify: `lca check`, then send a chat message from the phone.

## Afterwards

- Once the new VM works, **destroy the droplet** (powered-off droplets still
  bill — see [DO.md](DO.md)).
- Optionally remove the old machine from the Tailscale admin console
  (login.tailscale.com → Machines).

## What actually happened: the ESXi move (2026-10-01)

The steps above are the plan. This is the record of the first real run, from
the 8 GB droplet to an ESXi VM (`jmurynubnt`): Xeon E5-2680 v2, 62 GiB RAM,
no GPU, one 300 GB virtual disk on host-level **RAID 5**. Everything below went
wrong or needed a decision the plan above did not mention.

### The PATH bug in `~/.bashrc`

The VM's `~/.bashrc` ended with

```bash
export PATH="$HOME/.local/bin"
```

which *replaced* PATH instead of extending it, so every login shell lost
`/usr/bin` and `/bin`, so any command not given a full path failed with "command
not found". Fixed by prepending, with a guard so re-sourcing doesn't stack it
(original kept as `~/.bashrc.bak-20261001`):

```bash
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
```

If a fresh VM's shell can't find `sudo`, check this before anything else:
`echo "$PATH"`.

### LVM used only 100 GB of the 300 GB disk

The Ubuntu Server installer's default LVM layout gives the root LV about
100 GB and leaves the rest of the volume group unallocated. Models are
9–19 GB each, so this runs out fast. Check with `sudo vgs` (look at `VFree`),
then grow root and its filesystem in one step:

```bash
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
```

`/` went from 98 G to 292 G, online, with no reboot.

### RAID 5 underneath: what the backups do and do not cover

The datastore is RAID 5. (This section first said RAID 0; that was wrong.) The
VM can't see it (one virtual disk, empty `/proc/mdstat`), so no guest-side
check will tell you either way. RAID 5 survives one failed disk. It is not a
backup: a backup on the same virtual disk goes with it if the datastore, the
host or the VM's disk is lost, and RAID copies a deletion or a corruption as
faithfully as anything else. The backup timer (`backup.sh --install-timer`)
covers the schedule. An off-box pull to the Mac was built and then dropped by
the owner (2026-10-02), so every backup is on this VM; see RESUME.md.

### Passwordless sudo for the Claude session

A Claude Code session did most of this migration, and most of it needs root.
For the session the owner added a temporary rule:

```bash
echo 'jmuryn ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/jmuryn
sudo chmod 440 /etc/sudoers.d/jmuryn
```

Two lessons. **Delete it when the work is done** (`sudo rm
/etc/sudoers.d/jmuryn`, then `sudo -k; sudo -n true` must be refused).
Passwordless sudo also turns any test that calls `sudo` into a test that
changes the host: the unit suite rewrote `/etc/update-motd.d` 18 times on this
VM. Run the suite only via `make gates-container`, never on a real machine.

### Ubuntu 22.04 → 24.04 in place

The VM came with 22.04. The upgrade itself was uneventful, but four things
had to be done in order:

1. Install all 22.04 updates and **reboot first**; `do-release-upgrade` refuses
   to start while `/var/run/reboot-required` exists.
2. Run the upgrade **detached**, so a dropped SSH session (or the Claude session
   ending) can't kill it halfway:
   `sudo systemd-run --unit=lca-release-upgrade -p StandardOutput=append:/var/log/lca-release-upgrade.log -p StandardError=append:/var/log/lca-release-upgrade.log env DEBIAN_FRONTEND=noninteractive do-release-upgrade -f DistUpgradeViewNonInteractive`
   The non-interactive view doesn't reboot by itself. Check
   `/var/log/dist-upgrade/main.log`, then reboot.
3. The upgrade disables third-party apt sources. Point `docker.list` and
   `tailscale.list` at `noble` (Tailscale: fresh keyring and list from
   `pkgs.tailscale.com/stable/ubuntu/noble.*`), then `apt update && apt full-upgrade`.
4. **Rebuild the venv**: 22.04's Python 3.10 venv doesn't run on 24.04's 3.12.
   `sudo scripts/install_python.sh` notices and rebuilds it; confirm with
   `.venv/bin/aider --version`.

Take an ESXi snapshot before step 2, and delete it once the VM has proven
itself, because snapshots grow and slow the disk. Stay on 24.04 (LTS); don't
move on to 26.04 as part of a migration.

### 16 vCPUs, 8 cores per socket, and NUMA

The VM started with 8 vCPUs. It now has 16: **2 sockets × 8 cores**, set
with the VM powered off. That is more cores than one E5-2680 v2 socket has
(10), so the guest sees **two NUMA nodes** (`lscpu | grep NUMA`), each with
half the RAM.

Measured on qwen2.5-coder:14b:

| | reading | writing |
|---|---|---|
| 8 threads (8-vCPU stand-in, see below) | 6.7 tok/s | 3.4 tok/s |
| 16 threads | 13.2 tok/s | 4.3 tok/s |

Reading (prompt processing) is compute-bound and doubled. Writing is
memory-bound and gained about 30%. The 8-thread row was measured on the
16-vCPU VM with `num_thread=8`, because `lca speed` was never run before the
resize.

Two NUMA nodes need one more setting. Ollama copies the weights into its own
memory, and the kernel puts those pages wherever there is room. On this VM
that was mostly one node, because the other was full of page cache. Then half
the threads read every weight over the inter-socket link, and qwen2.5-coder:32b
wrote at **1.0 tok/s at 8, 12 and 16 threads alike**. Running Ollama under
`numactl --interleave=all` spreads the weights evenly over both nodes:
32b went to **2.0 tok/s**, and 14b was unchanged (4.3). The tune service now
sets this by itself on any machine with more than one NUMA node; see
PERFORMANCE.md.

### Reaching the ESXi host itself over Tailscale

The ESXi host's management interface (10.1.20.18) is on the same LAN as the VM
(10.1.20.35) but is not on the tailnet. The VM advertises a **/32 subnet
route** to just that one address, so the host UI is reachable from the Mac
or phone with no route to the rest of the LAN:

```bash
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' \
  | sudo tee /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
sudo tailscale set --advertise-routes=10.1.20.18/32
```

Then **approve the route** in the Tailscale admin console (Machines →
jmurynubnt → Edit route settings). It does nothing until approved. A Linux
client also needs `--accept-routes`; macOS and iOS accept routes by default.
Keep it a /32, because advertising the whole /24 would put every device on the
home LAN onto the tailnet. If the VM is down, the route goes with it; the
console at the host itself is the fallback.
