# traefik-edge — per-server HTTPS edge

Traefik's Docker provider only sees containers on its own host, so every
server that runs web-exposed stacks needs an edge proxy on that host. Either
path below keeps service labels **identical** to the conventions used on
Local (`services/traefik`):

- entrypoints named `http` / `https`
- cert resolver named `myresolver`
- external docker network `proxy`
- middlewares `admin-auth@file` and `AddForwardedHeader@file`

Per service, the only external requirement is a Route53 A record pointing the
service's hostname at the IP of the server that hosts it.

## Path 1 — server without an existing proxy: deploy this stack

Copy the `traefik-edge-template` stack block in `main.toml`, drop
`template = true`, set `server = "<name>"` and the `EDGE_NAME=<server-slug>`
line in `pre_deploy`. No new files needed. One-time server prerequisites:

```bash
docker network create proxy
# fetch-secrets-pre-deploy.sh needs the Infisical CLI on the periphery mount:
cp $(which infisical) /etc/komodo/bin/infisical
```

Secrets come from Infisical at deploy time: root (`/`) supplies
`DOMAIN_NAME` + `LETSENCRYPT_EMAIL`, `/traefik-edge` supplies `BASIC_AUTH`
(htpasswd format, generate with `htpasswd -nB admin`). The dashboard is
served at `traefik-<EDGE_NAME>.<DOMAIN_NAME>` behind `admin-auth`.

## Path 2 — server already running Coolify (ex44): reuse Coolify's proxy

Coolify's proxy (`coolify-proxy`) is itself Traefik bound to 80/443, with
entrypoints already named `http`/`https` — so instead of fighting over port
443, teach it our conventions once and don't deploy this stack there at all.

In the Coolify UI → **Servers → \<server\> → Proxy**:

### 1. Edit the proxy configuration (its docker-compose)

Attach the proxy to the external `proxy` network (keep `coolify`):

```yaml
services:
  traefik:
    networks:
      - coolify
      - proxy

networks:
  coolify:
    external: true
  proxy:
    external: true
```

Append to the traefik service's `command:` list:

```yaml
      # homelab additions — resolver + conventions matching services/traefik
      - '--certificatesresolvers.myresolver.acme.tlschallenge=true'
      - '--certificatesresolvers.myresolver.acme.email=<LETSENCRYPT_EMAIL>'
      - '--certificatesresolvers.myresolver.acme.storage=/traefik/acme-myresolver.json'
      - '--serverstransport.insecureskipverify=true'
      - '--experimental.plugins.AddForwardedHeader.modulename=github.com/jerrywoo96/AddForwardedHeader'
      - '--experimental.plugins.AddForwardedHeader.version=v1.0.1'
```

(Coolify's own `letsencrypt` resolver keeps using `/traefik/acme.json`; the
`myresolver` one gets its own storage file so they never collide.)

### 2. Add a dynamic configuration file (e.g. `homelab.yaml`)

Coolify's proxy already runs a file provider watching `/traefik/dynamic/`.
The `env` go-template used by `config.yaml` here isn't available there, so
paste the htpasswd hash literally:

```yaml
http:
  middlewares:
    admin-auth:
      basicAuth:
        users:
          - "admin:<htpasswd-hash>"   # generate: htpasswd -nB admin
    AddForwardedHeader:
      plugin:
        AddForwardedHeader:
          by: Traefik
          forHeader: X-Real-Ip
```

### 3. Restart the proxy

Then deploy/redeploy the homelab stacks on that server — their labels are
picked up as-is (they just need to be on the `proxy` network, which they
already are).

### Caveats

- Coolify's **"Reset configuration"** button (and possibly major Coolify
  upgrades) regenerates the proxy config and drops these additions. If a
  service on that server suddenly loses HTTPS, re-apply steps 1–2 from this
  file.
- Router names must be unique across the whole proxy — homelab router names
  (e.g. `grocy`, `restic`) must not collide with Coolify-managed app routers.
