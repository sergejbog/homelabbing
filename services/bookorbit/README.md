# bookorbit: the Pi's book library

`https://bookorbit.pi.sniperoo.app`, tailnet only, behind the Pi's Traefik
(route file `services/traefik/dynamic/bookorbit.yaml`). Komodo stack
`bookorbit` deploys this folder. [BookOrbit](https://github.com/bookorbit/bookorbit)
(AGPL-3.0) is a library and reader for EPUB, PDF, comics and audiobooks,
with Kobo, KOReader and OPDS sync.

## Containers

| Container | Image | uid | Networks | Data |
|---|---|---|---|---|
| `bookorbit` | `ghcr.io/bookorbit/bookorbit:3.10.0` | 65528 | `proxy`, `egress`, `db` | `/srv/bookorbit/{data,books,tmp}` |
| `bookorbit-db` | `pgvector/pgvector:0.8.7-pg18` | 65527 | `db` (internal) | `/srv/bookorbit/postgres` |

Both images are pinned by multi-arch digest. Both containers are
`read_only` with `cap_drop: ALL`. The uids are unused on the host, and
`pi-bookorbit.sh prep` gives them their folders.

- `data`: covers, the book dock (`/data/book-dock`), upload sessions and app state.
- `books`: the library root. Create libraries in the UI under `/books`
  (the folder picker shows nothing else).
- `tmp`: upload staging. It is on disk rather than tmpfs, so an upload does not sit in RAM.

## Secrets: Infisical, Homelab → prod → `/bookorbit`

The stack's `pre_deploy` writes them to `.env`
(`scripts/fetch-secrets-pre-deploy.sh bookorbit`), compose passes them to
the app, and `post_deploy` deletes the file. A change in Infisical goes
live on the next **Deploy** of the stack (a restart is not enough).

| Key | Value | Required |
|---|---|---|
| `POSTGRES_PASSWORD` | 24 random bytes, hex | yes |
| `JWT_SECRET` | 32 random bytes, hex (signs login tokens) | yes |
| `SETUP_BOOTSTRAP_TOKEN` | 16 random bytes, hex (one-time setup wizard) | yes, even after setup |
| `AI_ENCRYPTION_KEY` | 32 random bytes, hex | before saving an AI provider key |
| `BOOK_REQUEST_ENCRYPTION_KEY` | 32 random bytes, hex | before saving download-client or indexer credentials |
| `MIGRATION_ENCRYPTION_KEY` | 32 random bytes, hex | before saving migration source credentials |
| `EMAIL_ENCRYPTION_KEY` | 32 random bytes, hex | before saving SMTP credentials (the Pi has no SMTP) |

Generate each value in PowerShell 7 (change the byte count), paste it into
Infisical, then clear the clipboard:

```powershell
[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLower() | Set-Clipboard
```

- **`POSTGRES_PASSWORD` is read only on the first start**, when
  `/srv/bookorbit/postgres` is empty. Changing it later in Infisical breaks
  the app's login to the database. To rotate it, run `ALTER USER bookorbit
  PASSWORD '...'` in `bookorbit-db` first, then update Infisical and deploy.
  Postgres gets it through compose interpolation, not `env_file`, so the
  database container never sees the app's other keys.
- Changing an `*_ENCRYPTION_KEY` makes the credentials saved with the old
  key unreadable.
- Rotating `JWT_SECRET` signs everyone out.
- The values are container env vars, visible in `docker inspect` and in
  Komodo's container view.

## First start

1. Open `https://bookorbit.pi.sniperoo.app` and finish the setup wizard
   with `SETUP_BOOTSTRAP_TOKEN`. It creates the first admin.
2. Create a library under `/books`.

## Adding books

- **In the browser:** upload in the UI (up to 4 GB per file). The web UI
  sends each file in one request, and Traefik v3 cuts off a request it
  can't read within 60 s (`respondingTimeouts.readTimeout`, the default).
  That is fine for ebooks; a large audiobook over a slow tailnet path can
  fail. In that case copy it by hand (below), or raise the timeout on the
  `https` entrypoint in `services/traefik/traefik.yaml`. That is static
  config, so the change needs a Traefik restart and applies to every service.
  (The chunked upload API is only for the iPhone app: it requires App Attest.)
- **By hand:** `/srv/bookorbit` is root-only. Copy the files to the Pi, then
  move them in and give them to the app's uid:
  `sudo rsync -a --chown=65528:65528 <dir>/ /srv/bookorbit/books/<library>/`.
  Then scan the library in the UI.
- Upstream does not support network storage (SMB, NFS, FUSE) for any of
  these folders.

## Devices

The server is reachable only over the tailnet. A Kobo, a KOReader device or
the iPhone app can sync only if it is on the tailnet too, or after a public
route is added for the sync endpoints (see the webhooks plan for phase 9).

## Backups

`/srv/bookorbit/postgres` is a live database. For the backup stack, dump it
with `pg_dump` (in `bookorbit-db`, user `bookorbit`) rather than copying the
files. Back up `data` and `books` as files. Skip `tmp`.

## Upgrades

- Read the release notes first. Bump the tag and the digest together: the
  app runs its migrations by itself at start.
- A Postgres major upgrade (18 → 19) needs `pg_upgrade`, or a dump and
  restore. Changing the tag alone is not enough.
