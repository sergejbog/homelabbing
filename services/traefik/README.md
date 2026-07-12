# traefik — central edge proxy

The single public entrypoint for `*.{DOMAIN_NAME}`: one wildcard A record
points at this server (Local), and this Traefik routes every hostname to
wherever the service actually runs. Moving a stack between servers in
`main.toml` updates routing automatically — no DNS changes, ever.

```
*.DOMAIN_NAME ──A──> Local (this Traefik, wildcard TLS via DNS-01/Route53)
                       ├─ docker provider ──> containers on Local (labels, as before)
                       ├─ dynamic/edge-routes.yaml (GENERATED) ──> other servers
                       │    ex44 stacks   -> https://EX44_IP:443  (Coolify's Traefik re-routes by Host)
                       │    pi stacks     -> http://<pi-wg-ip>:<port>  (over WireGuard)
                       ├─ dynamic/config.yaml ──> hand-written routes (WG peers, periphery)
                       └─ catch-all (priority 1) ──> ex44  (Coolify-deployed apps)
```

## How routing stays in sync

`scripts/generate-edge-routes.sh` parses `main.toml` (stack → server) and each
remote stack's compose `Host(...)` labels, and writes
`dynamic/edge-routes.yaml` (gitignored). It runs in this stack's `pre_deploy`,
and the `Redeploy-If-Changed` action always deploys the traefik stack last —
so every push regenerates routes. The file provider watches `/dynamic` and
hot-reloads without restarting the container.

Conventions (set in a stack's `environment` block in `main.toml`):

- `EDGE_SKIP=true` — don't route this stack (e.g. `restic-server-pi`, which
  shares hostnames with the ex44 `restic-server`).
- `EDGE_PORT=<n>` — for direct (non-proxy) servers like the Pi: the published
  host port to forward to. Without it, the first published port in the compose
  file is used. Pi stacks should publish their port on the WireGuard IP only,
  e.g. `"10.49.0.2:8090:80"`.
- Adding a new server: add a case to `generate-edge-routes.sh` (either an
  "edge" server that re-encrypts to :443 like ex44, or a "direct" one like the
  Pi) — plus the `[[server]]` block in `main.toml` as usual.

## TLS

`myresolver` uses DNS-01 via Route53 (wildcard DNS means every hostname
resolves here, and the catch-all needs a wildcard cert, which only DNS-01 can
issue). The catch-all router orders `{DOMAIN_NAME}` + `*.{DOMAIN_NAME}`; other
routers are covered by the wildcard and don't order their own certs — except
deeper names like `ex44.periphery.{DOMAIN_NAME}` (a TLS wildcard only covers
one label), which get individual certs automatically.

acme.json lives at `/etc/komodo/traefik/letsencrypt` on the host (absolute
path, so a repo re-clone can't delete it).

## Secrets (Infisical `/traefik`; root `/` supplies DOMAIN_NAME + LETSENCRYPT_EMAIL)

| Key | Purpose |
|---|---|
| `BASIC_AUTH` | htpasswd line for `admin-auth@file` (dashboard etc.) |
| `WIREGUARD_PEER_IP` | WG peer for the hand-written routes in `dynamic/config.yaml` |
| `EX44_IP` | ex44 backhaul target (WireGuard IP) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | `traefik-dns01` IAM user (Route53 ChangeResourceRecordSets/ListResourceRecordSets on the zone, GetChange, ListHostedZonesByName) |
| `AWS_REGION` | `us-east-1` |
| `AWS_HOSTED_ZONE_ID` | zone ID for DOMAIN_NAME (skips zone lookup) |

## Notes

- ex44 backhaul re-encrypts to `:443` on purpose: Coolify's Traefik routes by
  the forwarded Host header; its cert isn't validated
  (`insecureSkipVerify: true`, global). Routing to `:80` would bounce clients
  through ex44's https redirect and loop. Coolify's own ACME renewals for
  centrally-routed hostnames fail harmlessly (users only ever see the
  wildcard cert from here).
- Generated routers deliberately don't add `AddForwardedHeader@file` — the
  ex44 hop applies it; applying it twice would overwrite the real client IP.
- The `proxy`-network aliases in the compose file give Local containers
  hairpin access to sibling hostnames. Post-cutover they're redundant (public
  DNS resolves everything to this host) and can be removed.
- The ex44 requirements (proxy network, `myresolver` conventions on Coolify's
  Traefik) are documented in `services/traefik-edge/README.md` Path 2.
