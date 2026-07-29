# INSTALL.md — manual installation (any Ubuntu 24.04 / Debian host)

For the zero-terminal DigitalOcean path, use [DO.md](DO.md) + [YOUR-TURN.md](YOUR-TURN.md)
instead. This page is for installing by hand: a non-DO cloud VM, a local
hypervisor VM (VMware / Proxmox / KVM), or a spare machine.

## Sizing

| RAM | What you get (auto-tuned) |
|---|---|
| 4–8 GB | `qwen2.5-coder:3b`, ctx 4096 — fast, basic |
| 9–15 GB | `qwen2.5-coder:7b`, ctx 8192 — the sweet spot for 8–12 GB VMs |
| 16–23 GB | `qwen2.5-coder:14b`, ctx 8192 — noticeably smarter |
| 24+ GB | `qwen2.5-coder:14b`, ctx 16384 (32 GB+: pin `32b` manually) |

- **CPU**: any x86_64 or arm64. More cores = faster tokens; no config needed.
- **Disk**: 50 GB comfortable; keep ≥ 15 GB free for models.
- **OS**: Ubuntu 24.04 LTS (primary) or Debian 12+. Needs systemd.

## Install

```bash
git clone https://github.com/mpjmsenc-dev/local-code-agent.git
cd local-code-agent
chmod +x *.sh scripts/*.sh
./setup.sh
```

Run as a normal user with sudo rights, or as root — both work. Non-interactive
shells auto-confirm every prompt, so `./setup.sh </dev/null` is fully unattended.

### What setup.sh does, in order

1. `scripts/install_dependencies.sh` — apt update/upgrade + base packages
   (curl, git, python3(-venv/-pip), build-essential, jq, nftables, …), each verified.
2. `scripts/install_git.sh` — git present; warns if you have no global identity
   (aider auto-commits).
3. `scripts/install_docker.sh` — Docker Engine from the official Docker apt repo
   (arch- and distro-aware), service enabled, your user added to the `docker`
   group, hello-world smoke test. Skipped when `SKIP_DOCKER=true`.
4. `scripts/install_python.sh` — project venv + `aider-chat` (honors `AIDER_VERSION`).
5. `scripts/install_ollama.sh` — official Ollama installer + systemd drop-in
   rendered from `.env` and `config/ollama.env`; verifies the API.
6. `scripts/tune.sh` — auto-tune model/context to this machine's RAM.
7. Pull `MODEL_NAME` if absent + one **real generation** as a smoke test.
8. `scripts/install_webui.sh` — Open WebUI container (when `ENABLE_WEBUI=true`).
9. `scripts/install_tailscale.sh` — Tailscale installed; login deferred to you.
10. Boot services: `local-code-agent-tune.service` (re-tune every boot) and
    `local-code-agent-netmode.service` (netmode persistence).
11. `./check-system.sh` + a next-steps summary.

Re-running `./setup.sh` at any time is safe — it reuses/repairs instead of
duplicating, and resumes cleanly after an interrupted install.

## After installing

```bash
sudo tailscale up          # log in via the printed URL
tailscale ip -4            # your private address
```

Phone setup: [PHONE.md](PHONE.md). Daily usage: `run-agent.sh` in any project
directory. Health: `./check-system.sh`.

## Local hypervisor notes (VMware / Proxmox / KVM)

- A fresh Ubuntu 24.04 **Server** guest with the specs above is all you need;
  then follow *Install*. Bridged or NAT networking both work — access goes
  through Tailscale either way.
- Change the VM's RAM later and reboot: auto-tune adapts, exactly like a droplet
  resize (this is the migration story — see [MIGRATE.md](MIGRATE.md)).
- arm64 guests (e.g. on Apple-silicon hosts) work unchanged; every installer is
  arch-aware.

## Full uninstall

```bash
cd /opt/local-code-agent            # or wherever you cloned it
sudo ./netmode.sh online            # remove any egress lockdown
sudo systemctl disable --now local-code-agent-tune.service local-code-agent-netmode.service || true
sudo rm -f /etc/systemd/system/local-code-agent-{tune,netmode}.service
sudo rm -rf /etc/local-code-agent

sudo docker rm -f open-webui        # WebUI container
sudo docker volume rm open-webui    #   ... and its data (chats!) — skip to keep
sudo systemctl disable --now ollama
sudo rm -rf /etc/systemd/system/ollama.service.d
sudo rm -f /etc/systemd/system/ollama.service /usr/local/bin/ollama
sudo rm -rf /usr/share/ollama       # includes all downloaded models
sudo userdel ollama 2>/dev/null; sudo groupdel ollama 2>/dev/null

sudo tailscale logout; sudo apt-get remove -y tailscale   # optional
sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin  # optional
sudo systemctl daemon-reload
cd .. && sudo rm -rf local-code-agent
```
