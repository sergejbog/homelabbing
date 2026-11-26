# Backups

Komodo schedules the backups, containers do the work, and the storage
refuses deletes. Every server backs up its `/srv` with restic into its own
folder of one Backblaze B2 bucket.

## How a night runs

Three Komodo procedures per server (Europe/Skopje time):

1. **`backup-<server>-dumps`, 03:30.** Each dump job (in `<server>.yaml`)
   uses the image and uid of the service it dumps and writes a consistent
   copy to `/srv/backup/dumps/<service>/`. On the Pi, most critical first:
   - `dump-vaultwarden`: `vaultwarden backup`, a `VACUUM INTO` copy, to
     `db.sqlite3`. Next to it, `BackupCoreDatabase` dumps Komodo's own
     database into `/srv/komodo/backups` (Komodo keeps the last 14);
   - `dump-infisical`, then `dump-bookorbit`: `pg_dump -Fc` to `db.dump`,
     checked with `pg_restore --list`. They log in as `backup`, a role
     that can read every table and change nothing (`pg_read_all_data`),
     made by `backup-host.sh pg-reader`.

   **One stack job per stage:** Komodo marks the stack busy for a
   `RunStackService` and refuses a second one while it runs, so jobs of
   the same stack can't share a stage.
2. **`backup-<server>`, 04:00: the upload.** `restic-backup` reads `/srv`
   read-only (minus `excludes/<server>.txt`: the live database files,
   caches, and data kept elsewhere) and uploads to `<bucket>/<server>/`.
   It is its own procedure so that a failed dump doesn't stop it: the
   failed dump's last good copy goes up with everything else.
3. **`backup-<server>-check`, Sundays at 05:00:** `restic check
   --read-data-subset=10%`.

If a stage fails, its procedure stops and fails, and Komodo raises a
failure alert. Alerts aren't delivered anywhere yet (ntfy comes later), so
check the procedures' state in Komodo.

## Why it is safe against a compromised server

- **The server's B2 key can't delete.** `backup-<server>` has only
  `listBuckets listFiles readFiles writeFiles` on its own prefix. restic's
  S3 backend only *hides* files on delete, which `writeFiles` allows, so
  normal operation works. A key without `deleteFiles` cannot remove a
  version.
- **Object Lock (governance, 30 days)** keeps every uploaded version for 30
  days, even against a key that could delete. Only a key with
  `bypassGovernance` could, and none exists: the master key is regenerated
  and discarded after setup.
- **Hidden versions are kept 30 more days** (a lifecycle rule), so a "hide
  everything" attack leaves at least 30 days to notice and unhide.
- **Forget and prune never run on a server.** They run from the admin PC,
  with `--keep-within-*` policies only, so bogus new snapshots from a
  compromised server cannot push the real ones out of the policy.
- **Pinned code.** `RunStackService` re-clones the repo before every run, so
  the stack is pinned with `commit` in `main.toml`. A push to `main` can't
  change what runs at night until a reviewed PR bumps that sha.
- **Each server has its own key and restic password**, in root-only files in
  `/srv/backup/secrets/`. They are not in Komodo, Infisical, git or
  `docker inspect`. Copies are in Vaultwarden.
- The restic container runs as root with only `DAC_READ_SEARCH`, a
  read-only root filesystem and `/srv` mounted read-only. The dump jobs
  never see the B2 key or the restic password, nor a database owner's
  password: the Postgres ones use the read-only `backup` role, whose
  password is generated on the server (`/srv/backup/dump-secrets/`).

Retention (applied from the PC): 7 daily, 4 weekly, 6 monthly.

## Changing the backup logic

1. Change files here in a PR.
2. Bump `commit` of the `backup-<server>` stacks in `main.toml` to a commit
   that contains the change. **Merge with "Create a merge commit"**, not
   squash or rebase: those rewrite the sha, and the pin would point at a
   commit `main` doesn't contain.
3. Execute the `pi` resource sync in Komodo.

## Adding a server

1. Periphery on the server, connected to Core.
2. `services/backup/<server>.yaml` with its dump jobs (or none), and
   `excludes/<server>.txt`.
3. In `main.toml`, copy the `backup-pi` stack and its three procedures,
   with the new name, `SERVER=<server>` and `file_paths`. Keep one stack
   job per stage.
4. On the server, as root: copy `setup/backup-host.sh` there, then run
   `prep` with that server's dump folders and their uids, and
   `pg-reader <dump> <container> <superuser> <gid>` for each Postgres.
   Run each dump job once by hand (`docker compose -p backup-<server>
   -f docker-compose.yaml -f <server>.yaml --profile jobs run --rm <job>`
   with `SERVER=<server>`).
5. On the PC, in your own PowerShell window: generate a new B2 master key,
   then run `setup/b2-setup.ps1 -Bucket <bucket> -Server <server>`. It makes
   the key, places the secrets, asks you to save them in Vaultwarden and
   runs `init`. Regenerate the master key afterwards and don't save it.
6. Run the procedure once from Komodo, then
   `sudo bash backup-host.sh status` on the server.

## Seeing and revoking keys

The B2 web UI doesn't list the keys `b2-setup.ps1` makes. In your own
PowerShell window, with a newly generated master key:

```powershell
pwsh -File setup/b2-keys.ps1                    # list them
pwsh -File setup/b2-keys.ps1 -Delete backup-pi  # revoke one
```

If a server is compromised, delete its key first: what it already
uploaded stays under Object Lock either way. Then rebuild the server and
run `b2-setup.ps1` for it again; it keeps the existing restic password.
Generate a new master key afterwards and don't save it.

## Restoring

From any machine with restic, the repository URL, the server's restic
password and a key that can read the bucket (the admin key or the server's
own):

```sh
export RESTIC_REPOSITORY=s3:https://s3.<region>.backblazeb2.com/<bucket>/<server>
export AWS_ACCESS_KEY_ID=<key id> AWS_SECRET_ACCESS_KEY=<key>   # read from Vaultwarden
restic snapshots
restic restore latest --target /tmp/restore --include /srv/backup/dumps
```

- Infisical: `pg_restore` `dumps/infisical/db.dump` into an empty
  database. It also needs `/srv/infisical/secrets` (the `encryption_key`).
- BookOrbit: `pg_restore` `dumps/bookorbit/db.dump` into an empty
  database, with `/srv/bookorbit/data` from the snapshot. The books are
  not backed up (replaceable, and too big): they come from their own
  disk, at the same paths, or the library rescans what is left.
- Vaultwarden: stop it, put `dumps/vaultwarden/db.sqlite3` in place as
  `data/db.sqlite3` with the rest of `data/`, and start it.
- After restoring a Postgres database, rerun `pg-reader` for it: a dump
  does not carry roles, so the `backup` role is gone.
- Komodo: `km database restore` from the `/srv/komodo/backups` folder.

If files were hidden (deleted) by an attacker, unhide them first: in the
B2 web UI, show hidden files and unhide them, which removes the hide
markers. restic only sees the current versions.
