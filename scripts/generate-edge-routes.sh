#!/bin/sh

# Generate Traefik file-provider routes for stacks hosted on servers other than
# Local, so the central Traefik (services/traefik) can forward them. Source of
# truth is main.toml: each non-template [[stack]] with server != "Local" gets
# one router per Host(...) label found in its compose file(s).
#
# Backends by server:
#   ex44         -> https://EX44_IP:443 (re-encrypt to Coolify's Traefik, which
#                   routes by Host header; insecureSkipVerify is global)
#   raspberry-pi -> http://<ip from [[server]] address>:<port> over WireGuard;
#                   port = EDGE_PORT in the stack's environment, else the first
#                   published host port in the compose file
#
# Stack environment conventions (read from main.toml, not the compose):
#   EDGE_SKIP=true   -> stack is not routed (e.g. restic-server-pi, which
#                       shares hostnames with the ex44 restic-server)
#   EDGE_PORT=<n>    -> published host port to use for direct (pi) backends
#
# Runs as `sh` (dash) inside the Komodo periphery container from the traefik
# stack's pre_deploy: POSIX sh + awk/sed only. Also runnable on a workstation:
#   sh scripts/generate-edge-routes.sh [repo-root]
#
# Output: services/traefik/dynamic/edge-routes.yaml (gitignored; the traefik
# file-provider watches the directory and hot-reloads). The file is only
# replaced when content changes, so no-op runs cause no reload.

set -eu
LC_ALL=C
export LC_ALL

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
MAIN_TOML="$REPO_ROOT/main.toml"
OUT_DIR="$REPO_ROOT/services/traefik/dynamic"
OUT="$OUT_DIR/edge-routes.yaml"
TMP="$OUT.tmp"

warn() { echo "generate-edge-routes: WARN: $*" >&2; }

[ -f "$MAIN_TOML" ] || { echo "generate-edge-routes: $MAIN_TOML not found" >&2; exit 1; }
mkdir -p "$OUT_DIR"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
: > "$WORK/routers"
: > "$WORK/services"
: > "$WORK/hosts"

# ---------------------------------------------------------------------------
# Pass 1: flatten main.toml into pipe-delimited rows.
#   STACK|name|server|linked_repo|run_directory|files|skip|port
#   SERVER|name|host   (host = address without scheme/port)
# State resets on every [[...]] header, so name/server keys inside procedures,
# actions, repos etc. are ignored. Template stacks are dropped.
# ---------------------------------------------------------------------------
awk '
function flush() {
  if (kind == "stack" && !tmpl && name != "")
    printf "STACK|%s|%s|%s|%s|%s|%s|%s\n", name, server, repo, rundir, files, skip, port
  if (kind == "server" && name != "") {
    host = addr
    sub(/^https?:\/\//, "", host)
    sub(/:[0-9]+.*$/, "", host)
    printf "SERVER|%s|%s\n", name, host
  }
  kind = ""; name = ""; server = ""; repo = ""; rundir = ""; files = ""
  tmpl = 0; skip = 0; port = ""; addr = ""
}
/^\[\[stack\]\]/  { flush(); kind = "stack";  next }
/^\[\[server\]\]/ { flush(); kind = "server"; next }
/^\[\[/           { flush(); next }
kind != "" {
  if ($0 ~ /^name = /)               { v = $0; gsub(/^name = "|"$/, "", v); name = v }
  else if ($0 ~ /^template = true/)  { tmpl = 1 }
  else if ($0 ~ /^server = /)        { v = $0; gsub(/^server = "|"$/, "", v); server = v }
  else if ($0 ~ /^linked_repo = /)   { v = $0; gsub(/^linked_repo = "|"$/, "", v); repo = v }
  else if ($0 ~ /^run_directory = /) { v = $0; gsub(/^run_directory = "|"$/, "", v); rundir = v }
  else if ($0 ~ /^address = /)       { v = $0; gsub(/^address = "|"$/, "", v); addr = v }
  else if ($0 ~ /^file_paths = /)    { v = $0; gsub(/^file_paths = \[|\]$|"| /, "", v); gsub(/,/, " ", v); files = v }
  else if ($0 ~ /EDGE_SKIP *=* *true/)   { skip = 1 }
  else if ($0 ~ /EDGE_PORT *=* *[0-9]/)  { v = $0; sub(/.*EDGE_PORT *=* */, "", v); sub(/[^0-9].*$/, "", v); port = v }
}
END { flush() }
' "$MAIN_TOML" > "$WORK/rows"

server_host() {
  awk -F'|' -v s="$1" '$1 == "SERVER" && $2 == s { print $3; exit }' "$WORK/rows"
}

# ---------------------------------------------------------------------------
# Pass 2: build router/service records from each remote stack's compose labels.
# ---------------------------------------------------------------------------
while IFS='|' read -r tag name server repo rundir files skip port; do
  [ "$tag" = "STACK" ] || continue
  [ "$server" = "Local" ] && continue
  [ "$skip" = "1" ] && continue
  if [ "$repo" != "homelabbing" ]; then
    warn "stack $name: linked_repo '$repo' is not this repo, skipping"
    continue
  fi

  # Resolve the backend service for this stack's routers.
  case "$server" in
    ex44)
      svc="edge-ex44"
      echo 'edge-ex44|https://{{ env "EX44_IP" }}:443' >> "$WORK/services"
      ;;
    raspberry-pi)
      pi_host=$(server_host raspberry-pi)
      if [ -z "$pi_host" ]; then
        warn "stack $name: no address for server raspberry-pi, skipping"
        continue
      fi
      eport="$port"
      if [ -z "$eport" ]; then
        for f in $files; do
          eport=$(sed -n 's/^ *- *"\{0,1\}\([0-9.]*:\)\{0,1\}\([0-9][0-9]*\):[0-9].*/\2/p' \
            "$REPO_ROOT/$rundir/$f" 2>/dev/null | head -n 1)
          [ -n "$eport" ] && break
        done
      fi
      if [ -z "$eport" ]; then
        warn "stack $name: no EDGE_PORT and no published port in compose, skipping"
        continue
      fi
      svc="edge-pi-$name"
      echo "$svc|http://$pi_host:$eport" >> "$WORK/services"
      ;;
    *)
      warn "stack $name: unknown server '$server' (extend the case in this script), skipping"
      continue
      ;;
  esac

  for f in $files; do
    compose="$REPO_ROOT/$rundir/$f"
    if [ ! -f "$compose" ]; then
      warn "stack $name: $rundir/$f not found, skipping file"
      continue
    fi
    if grep -q 'routers\.[A-Za-z0-9_-]*\.rule=.*||' "$compose"; then
      warn "stack $name: multi-host rule (||) found in $rundir/$f; only the first Host() is routed"
    fi
    sed -n 's/.*traefik\.http\.routers\.\([A-Za-z0-9_-]*\)\.rule=Host(`\([^`]*\)`).*/\1 \2/p' "$compose" |
    while read -r rname rhost; do
      [ -n "$rname" ] || continue
      if grep -Fqx "$rhost" "$WORK/hosts"; then
        warn "stack $name: duplicate host $rhost (router $rname) skipped"
        continue
      fi
      if grep -q "^$rname|" "$WORK/routers"; then
        warn "stack $name: duplicate router name $rname skipped"
        continue
      fi
      echo "$rhost" >> "$WORK/hosts"
      host_tpl=$(printf '%s' "$rhost" | sed 's/${DOMAIN_NAME}/{{ env "DOMAIN_NAME" }}/g')
      echo "$rname|$host_tpl|$svc" >> "$WORK/routers"
    done
  done
done < "$WORK/rows"

# ---------------------------------------------------------------------------
# Emit deterministic YAML (sorted), replace output only when content changed.
# ---------------------------------------------------------------------------
{
  echo "# GENERATED by scripts/generate-edge-routes.sh from main.toml - DO NOT EDIT."
  echo "# Routers for stacks hosted on servers other than Local, forwarded by the"
  echo "# central Traefik. Regenerated by the traefik stack's pre_deploy."
  echo "http:"
  if [ -s "$WORK/routers" ]; then
    echo "  routers:"
    sort -t'|' -k1,1 "$WORK/routers" | while IFS='|' read -r rname host_tpl svc; do
      echo "    edge-$rname:"
      echo "      rule: Host(\`$host_tpl\`)"
      echo "      entryPoints:"
      echo "        - https"
      echo "      service: $svc"
      echo "      tls:"
      echo "        certResolver: myresolver"
    done
    echo "  services:"
    sort -u "$WORK/services" | while IFS='|' read -r sname surl; do
      echo "    $sname:"
      echo "      loadBalancer:"
      echo "        servers:"
      echo "          - url: '$surl'"
    done
  else
    echo "  routers: {}"
    echo "  services: {}"
  fi
} > "$TMP"

if [ -f "$OUT" ] && cmp -s "$TMP" "$OUT"; then
  rm -f "$TMP"
  echo "generate-edge-routes: $OUT unchanged ($(grep -c '|' "$WORK/routers" || true) routers)"
else
  mv "$TMP" "$OUT"
  echo "generate-edge-routes: wrote $OUT ($(grep -c '|' "$WORK/routers" || true) routers)"
fi
