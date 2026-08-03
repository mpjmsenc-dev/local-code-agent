# MIGRATE.md — moving from DigitalOcean to your own hypervisor

DigitalOcean snapshots **cannot be downloaded**, so a snapshot is not a migration
path off DO. This repository is: everything on the droplet was installed by these
scripts, and everything personal fits in one `backup.sh` tarball. Auto-tune then
adapts the stack to the new VM's specs automatically — the new machine does not
need to match the droplet's size.

## On the droplet (source)

```bash
cd /opt/local-code-agent
./backup.sh
```

This writes `backups/local-code-agent-backup-<timestamp>.tar.gz` containing the
Open WebUI data volume (your account + all chats), your `.env`, and the list of
installed models (names only — model blobs re-download on the new machine).

Copy it to your computer (run this **on your computer**, not the droplet):

```bash
scp root@<droplet-ip>:/opt/local-code-agent/backups/local-code-agent-backup-*.tar.gz .
```

## On the new VM (target)

1. Create a fresh **Ubuntu 24.04 Server** VM in VMware / Proxmox / KVM
   (sizing guidance in [INSTALL.md](INSTALL.md); arm64 is fine).
2. Install the stack:

   ```bash
   git clone https://github.com/mpjmsenc-dev/local-code-agent.git /opt/local-code-agent
   cd /opt/local-code-agent
   chmod +x *.sh scripts/*.sh
   ./setup.sh
   ```

3. Copy the backup tarball onto the VM (run on your computer):

   ```bash
   scp local-code-agent-backup-*.tar.gz root@<vm-ip>:/opt/local-code-agent/backups/
   ```

4. Restore your data:

   ```bash
   cd /opt/local-code-agent
   ./restore.sh
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

6. Verify: `./check-system.sh`, then send a chat message from the phone.

## Afterwards

- Once the new VM works, **destroy the droplet** (powered-off droplets still
  bill — see [DO.md](DO.md)).
- Optionally remove the old machine from the Tailscale admin console
  (login.tailscale.com → Machines).
