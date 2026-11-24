# glance: the Pi's dashboard

`https://glance.pi.sniperoo.app`, tailnet only, behind the Pi's Traefik
(route file `services/traefik/dynamic/glance.yaml`). Komodo stack `glance`
deploys this folder; config changes go live on the next deploy of the stack.

## Secrets

Glance reads them itself with `${secret:<name>}` from `/run/secrets`. On the
Pi they are files in `/srv/glance/secrets` (root:65530 0640), written by
`pi-glance.sh secrets` (see the Pi rebuild guide), never in git:

| Secret | Used for |
|---|---|
| `secret_key` | session signing key (64 random bytes, base64) |
| `admin_password_hash` | bcrypt hash of the password of user `admin` |
| `email_second`, `email_third`, `email_fourth` | titles of the Gmail bookmarks |

`DOMAIN_NAME` is set in the compose file (`pi.sniperoo.app`); it is not a
secret.

## Gotcha: variables in comments

Glance fills in `${...}` on every line of an included file, comments too. An
unset variable or a missing secret file stops Glance from starting. To turn a
widget off, comment out its `$include:` line in `home.yml`, and keep widgets
that need extra variables in their own file.

## Widgets that are off

Commented out in `home.yml` until they exist on the Pi:

- `widgets/uptime-kuma.yml`: reads the status page `homepage` from
  `http://uptime-kuma:3001`, so the container must be named `uptime-kuma`
  and be on the `proxy` network.
- `widgets/grafana.yml`: an iframe of a Grafana public dashboard. It needs
  `GRAFANA_PUBLIC_DASHBOARD_ID`.
- `widgets/komodo.yml`: needs `KOMODO_URL`, `KOMODO_API_KEY` and
  `KOMODO_API_SECRET`. A good fit is `${secret:...}` and a key of a non-admin
  Komodo user with read access only. The template uses `KOMODO_URL` both for
  the API calls (from the container) and for the links (in your browser), so
  one URL has to work from both.
