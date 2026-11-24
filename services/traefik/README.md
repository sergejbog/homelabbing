# traefik: the Pi's reverse proxy

Serves `https://<name>.pi.sniperoo.app` for every service on the Raspberry
Pi, on the Pi's tailnet IP only (`100.65.226.80:443`). Nothing is reachable
from the internet.

- **Certificate:** one Let's Encrypt wildcard, `*.pi.sniperoo.app`, through
  a DNS-01 challenge at deSEC. The deSEC token can write one TXT record and
  nothing else. It lives on the Pi in `/srv/traefik/secrets`, never in git.
- **Routing:** file provider only. Traefik has no Docker socket and reads no
  container labels. Each service has one route file in `dynamic/`.
- **Deploys:** Komodo stack `traefik` (see `main.toml`). Route changes go
  live only when this stack is deployed; the file watcher then reloads them
  without a restart.

## Adding a route

Add `dynamic/<service>.yaml`:

```yaml
http:
  routers:
    <service>:
      rule: Host(`<service>.pi.sniperoo.app`)
      entryPoints:
        - https
      service: <service>
  services:
    <service>:
      loadBalancer:
        servers:
          - url: http://<container_name>:<port>
```

- The container must be on the external `proxy` network (internal: no
  internet). Give it a second, normal network only if it needs egress.
- **Never add a `tls:` section** to a router. It replaces the entrypoint's
  wildcard, and a per-host certificate would publish the service name in
  certificate transparency logs.
- To close a single path on a host, add a longer router for it with the
  `deny-all` middleware (`middlewares.yaml`), as `komodo.yaml` and
  `infisical.yaml` do.
