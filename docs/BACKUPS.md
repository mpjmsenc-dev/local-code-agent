# Backups

`backup.sh` captures the state that isn't trivially re-createable, and
`restore.sh` puts it back on a fresh install.

## What's in a backup

| Included | Not included (by design) |
|---|---|
| Open WebUI data volume — accounts, chat history, settings | The model blobs (multi-GB) — they re-pull on restore |
| Your `.env` | Ollama itself, Docker, Tailscale — reinstalled by `setup.sh` |
| The list of installed model names (`models.txt`) | |
| Which machine it came from (`meta`: host, RAM, model, context, timestamp) | |

Backups are gzipped tarballs in `backups/`, named
`local-code-agent-backup-YYYYMMDD-HHMMSS.tar.gz`. The WebUI container is briefly
paused around the volume archive so its SQLite database is captured consistently.

`meta` is there so a restore can tell you something useful rather than
something generic. `.env` carries the **source** machine's model and context
length, so restoring an 8 GB droplet's backup onto a 32 GB VM would otherwise
leave the big machine running the small model with nothing saying so. With it,
`restore.sh` names both sizes and points at `lca tune`; restoring onto the same
machine, it stays quiet. Backups taken before `meta` existed still restore
fine — you get the conditional advice instead of the specific one.

Read it without restoring anything:

```bash
tar xzf "$(ls -t backups/local-code-agent-backup-*.tar.gz | head -1)" -O ./meta
```

(The newest is selected explicitly rather than globbing: once you have more
than one backup — which is the point of `BACKUP_KEEP` — a bare `*.tar.gz` makes
`tar` treat the second archive as a *file to extract from the first*, and it
prints nothing useful.)

## Make one now

```bash
./backup.sh
```

Then copy it **off the machine** — a backup on the same disk won't survive a disk
loss:

```bash
# the path backup.sh just printed — not a * glob, which would pull every
# retained backup (BACKUP_KEEP defaults to 7, each holding the WebUI volume)
scp user@host:/path/to/local-code-agent/backups/local-code-agent-backup-20260101-120000.tar.gz .
```

Copying *all* of them off the box is a reasonable thing to want too — just do
it deliberately, with `scp -r .../backups/ .`, rather than by accident.

## Restore

On a fresh install (after `setup.sh`):

```bash
./restore.sh                 # newest backup in backups/
./restore.sh path/to/backup.tar.gz
```

Restore brings back the WebUI volume and `.env`, re-pulls the models listed in
the backup, and then runs `lca apply` so the restored `.env` is actually **in
effect** rather than merely on disk.

That last step matters more than it sounds. Some settings are baked into the
Ollama service and the chat app container when those are created, so putting
the old `.env` back does not move them on its own — and a restore replaces
every key at once. Without it a recovery could finish, report success, and
leave the box running the settings you had just replaced, during the one
operation whose whole purpose is putting things back how they were.

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
