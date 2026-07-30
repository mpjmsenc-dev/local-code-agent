# Backups

`backup.sh` captures the state that isn't trivially re-createable, and
`restore.sh` puts it back on a fresh install.

## What's in a backup

| Included | Not included (by design) |
|---|---|
| Open WebUI data volume — accounts, chat history, settings | The model blobs (multi-GB) — they re-pull on restore |
| Your `.env` | Ollama itself, Docker, Tailscale — reinstalled by `setup.sh` |
| The list of installed model names (`models.txt`) | |

Backups are gzipped tarballs in `backups/`, named
`local-code-agent-backup-YYYYMMDD-HHMMSS.tar.gz`. The WebUI container is briefly
paused around the volume archive so its SQLite database is captured consistently.

## Make one now

```bash
./backup.sh
```

Then copy it **off the machine** — a backup on the same disk won't survive a disk
loss:

```bash
scp user@host:/path/to/local-code-agent/backups/local-code-agent-backup-*.tar.gz .
```

## Restore

On a fresh install (after `setup.sh`):

```bash
./restore.sh                 # newest backup in backups/
./restore.sh path/to/backup.tar.gz
```

Restore brings back the WebUI volume and `.env`, then re-pulls the models listed
in the backup.

## Retention

Each run keeps the newest `BACKUP_KEEP` backups (default `7`) and prunes older
ones so they can't slowly fill the disk — the same disk headroom
`check-system.sh` guards (models want ≥15 GB free). Set `BACKUP_KEEP=0` in `.env`
to keep every backup instead.

Pruning is deliberately **skipped** when a run could not capture WebUI data it
believes exists — the volume is there but the archive failed, or Docker is down
so its contents can't be verified. Without that guard, a week of unattended runs
with Docker broken would quietly delete every backup that still held your
accounts and chat history. When that happens the run warns and keeps the older
backups; fix Docker and re-run `./backup.sh`. A machine with no WebUI data at all
(`ENABLE_WEBUI=false`, or Docker running with no `open-webui` volume) prunes
normally — there is nothing to lose.

## Automatic (scheduled) backups

Opt in to a systemd timer that runs the backup for you:

```bash
sudo ./backup.sh --install-timer     # enable
sudo ./backup.sh --uninstall-timer   # disable
```

- Schedule: `BACKUP_SCHEDULE` in `.env` (systemd `OnCalendar` syntax). **Quote the
  value** — `.env` is sourced by every script, so an unquoted value containing
  spaces breaks them all:

  ```bash
  BACKUP_SCHEDULE="*-*-* 03:30:00"   # default: 03:30 daily
  BACKUP_SCHEDULE="daily"
  BACKUP_SCHEDULE="Mon *-*-* 02:00:00"
  ```

  `install-timer` validates the value with `systemd-analyze calendar` and refuses a
  malformed one. Re-run `install-timer` after changing it.
- `Persistent=true`, so a run missed while the box was off happens at next boot.
- Check it: `systemctl list-timers local-code-agent-backup.timer`, or
  `./check-system.sh` (the Backups section shows the timer state and the age of
  the newest backup).

Scheduled backups still write to the same local disk, so they protect against
app-level data loss (accidental deletion, WebUI DB corruption), not disk failure —
keep copying important ones off-box.
