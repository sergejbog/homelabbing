# glance: the Pi's dashboard

`https://glance.pi.sniperoo.app`, tailnet only, behind the Pi's Traefik
(route file `services/traefik/dynamic/glance.yaml`). Komodo stack `glance`
deploys this folder; config changes go live on the next deploy of the stack.

## Secrets: Infisical, Homelab → prod → `/glance`

The stack's `pre_deploy` writes them to `.env` (`scripts/fetch-secrets-pre-deploy.sh
glance`), compose passes them to the container, and `post_deploy` deletes
the file. A change in Infisical goes live on the next **Deploy** of the stack
(a restart is not enough).

| Key | Value |
|---|---|
| `GLANCE_SECRET_KEY` | session signing key: 64 random bytes, base64 |
| `GLANCE_ADMIN_PASSWORD_HASH` | bcrypt hash of the password of user `admin` |
| `GLANCE_EMAIL_SECOND`, `GLANCE_EMAIL_THIRD`, `GLANCE_EMAIL_FOURTH` | titles of the Gmail bookmarks |

They end up as container env vars, visible in `docker inspect` and in
Komodo's container view. Keep that in mind before adding a key that unlocks
something else (use a read-only one).

`DOMAIN_NAME` is set in the compose file (`pi.sniperoo.app`); it is not a
secret.

## Gotcha: variables in comments

Glance fills in `${...}` on every line of an included file, comments too. An
unset variable stops Glance from starting. To turn a widget off, comment out
its `$include:` line in `home.yml`, and keep widgets that need extra
variables in their own file.

## Widgets that are off

Commented out in `home.yml` until they exist on the Pi. To turn one on, add
its keys to Infisical `/glance`, uncomment the include, and deploy.

- `widgets/uptime-kuma.yml`: reads the status page `homepage` from
  `http://uptime-kuma:3001`, so the container must be named `uptime-kuma`
  and be on the `proxy` network. No keys.
- `widgets/grafana.yml`: an iframe of a Grafana public dashboard. Key:
  `GRAFANA_PUBLIC_DASHBOARD_ID`.
- `widgets/komodo.yml`: keys `KOMODO_URL`, `KOMODO_API_KEY` and
  `KOMODO_API_SECRET`. Use the key of a non-admin Komodo user with read
  access only. The template uses `KOMODO_URL` both for the API calls (from
  the container) and for the links (in your browser), so one URL has to work
  from both.
