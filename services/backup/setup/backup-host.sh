#!/bin/bash
# Host side of the backup stack, run as root on each server. Komodo never
# runs this file; the owner (or an admin session) does, once per server and
# when a key changes.
#
#   sudo bash backup-host.sh prep <dump>:<uid> ...   e.g. prep infisical:70 vaultwarden:65533
#   sudo bash backup-host.sh pg-reader <dump> <container> <superuser> <gid>
#        a read-only Postgres role "backup" for a dump job, with a new
#        password in dump-secrets/<dump>_db_password (rerun to rotate it,
#        and after restoring that database: pg_dump does not carry roles)
#   <value> | sudo bash backup-host.sh secret <name> [--replace]
#        names: restic_password, restic_repository, s3_credentials (two lines: key id, key)
#   sudo bash backup-host.sh init      create the restic repo (or confirm it exists)
#   sudo bash backup-host.sh status    secrets, dumps and the latest snapshots
#   sudo bash backup-host.sh canary <server>
#        a tiny snapshot, then `forget` it with this server's key: the snapshot
#        file must stay in B2 as a hidden version (check in the B2 web UI).
#
# It prints names, sizes, permissions and restic summaries, never a secret.
set -euo pipefail
umask 077

BASE=/srv/backup
SECRETS=$BASE/secrets
DUMPS=$BASE/dumps
DUMP_SECRETS=$BASE/dump-secrets
# Keep in step with docker-compose.yaml.
IMAGE=restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"

# restic in the same image and with the same secrets as the nightly job.
restic_run() {
    local f
    for f in restic_repository restic_password s3_credentials; do
        [ -s "$SECRETS/$f" ] || die "missing $SECRETS/$f (run: secret $f)"
    done
    docker run --rm --read-only --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --tmpfs /tmp:size=256m \
        -e RESTIC_REPOSITORY_FILE=/run/secrets/restic_repository \
        -e RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
        -e AWS_SHARED_CREDENTIALS_FILE=/run/secrets/s3_credentials \
        -e RESTIC_CACHE_DIR=/tmp/cache \
        -v "$SECRETS/restic_repository:/run/secrets/restic_repository:ro" \
        -v "$SECRETS/restic_password:/run/secrets/restic_password:ro" \
        -v "$SECRETS/s3_credentials:/run/secrets/s3_credentials:ro" \
        "$IMAGE" "$@"
}

cmd_prep() {
    [ $# -gt 0 ] || die "usage: prep <dump>:<uid> ..."
    install -d -o root -g root -m 0700 "$BASE" "$SECRETS" "$DUMPS"
    local spec name uid
    for spec in "$@"; do
        name=${spec%%:*}; uid=${spec#*:}
        [[ $name =~ ^[a-z0-9-]+$ && $uid =~ ^[0-9]+$ ]] || die "bad spec: $spec"
        install -d -o "$uid" -g "$uid" -m 0700 "$DUMPS/$name"
        echo "dump dir $DUMPS/$name owned by $uid"
    done
}

# The dump job logs in as "backup", which can read every table and change
# nothing, so the job never holds the database owner's password. The new
# password goes only to the role (over docker exec's stdin) and to the file.
cmd_pg_reader() {
    local name=${1:-} ctr=${2:-} admin=${3:-} gid=${4:-} pw file
    [[ $name =~ ^[a-z0-9-]+$ && $ctr =~ ^[A-Za-z0-9_.-]+$ && $admin =~ ^[a-z_][a-z0-9_]*$ && $gid =~ ^[0-9]+$ ]] \
        || die "usage: pg-reader <dump> <container> <superuser> <gid of the dump job>"
    [ "$(docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null)" = true ] || die "container $ctr is not running"
    install -d -o root -g root -m 0700 "$DUMP_SECRETS"
    file=$DUMP_SECRETS/${name}_db_password
    pw=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    [ ${#pw} = 64 ] || die "could not make a password"
    tmp=$(mktemp "$DUMP_SECRETS/.tmp.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    printf '%s' "$pw" > "$tmp"
    chown root:"$gid" "$tmp"; chmod 0640 "$tmp"
    # The image's local socket trusts the superuser; no password needed.
    docker exec -i "$ctr" psql -X -q -v ON_ERROR_STOP=1 -U "$admin" -d postgres <<SQL
BEGIN;
SELECT 'CREATE ROLE backup' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'backup')\gexec
ALTER ROLE backup WITH LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '$pw';
GRANT pg_read_all_data TO backup;
COMMIT;
SQL
    pw=
    mv -f "$tmp" "$file"
    trap - EXIT
    echo "role backup in $ctr: login, pg_read_all_data only"
    echo "wrote $file (root:$gid 0640)"
}

cmd_secret() {
    local name=${1:-} replace=${2:-} value key_id key
    [ -d "$SECRETS" ] || die "run prep first"
    [ -n "$name" ] || die "usage: secret <name> [--replace]"
    if [ -e "$SECRETS/$name" ] && [ "$replace" != --replace ]; then
        die "$SECRETS/$name exists; pass --replace to overwrite it"
    fi
    # Windows clipboards and pipes add CR/LF; strip them.
    value=$(tr -d '\r')
    # Global, so the EXIT trap still sees it after die() inside this function.
    tmp=$(mktemp "$SECRETS/.tmp.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    case $name in
        restic_password)
            value=${value%%$'\n'*}
            [ ${#value} -ge 24 ] || die "restic_password: expected at least 24 characters"
            printf '%s' "$value" > "$tmp" ;;
        restic_repository)
            value=${value%%$'\n'*}
            [[ $value =~ ^s3:https://s3\.[a-z0-9-]+\.backblazeb2\.com/[a-z0-9-]{6,63}/[a-z0-9-]+$ ]] \
                || die "restic_repository: expected s3:https://s3.<region>.backblazeb2.com/<bucket>/<server>"
            printf '%s' "$value" > "$tmp" ;;
        s3_credentials)
            key_id=$(sed -n 1p <<<"$value"); key=$(sed -n 2p <<<"$value")
            [[ $key_id =~ ^[0-9a-fA-F]{20,40}$ ]] || die "s3_credentials: line 1 is not a B2 key id"
            [[ $key =~ ^[A-Za-z0-9+/=]{20,64}$ ]] || die "s3_credentials: line 2 is not a B2 application key"
            printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$key_id" "$key" > "$tmp" ;;
        *) die "unknown secret: $name" ;;
    esac
    chown root:root "$tmp"; chmod 0600 "$tmp"
    mv -f "$tmp" "$SECRETS/$name"
    trap - EXIT
    echo "wrote $SECRETS/$name ($(stat -c %s "$SECRETS/$name") bytes, root 0600)"
}

cmd_init() {
    local rc=0
    restic_run cat config > /dev/null 2>&1 || rc=$?
    case $rc in
        0) echo "repository already exists and the password opens it" ;;
        10) restic_run init ;;
        12) die "a repository exists but this password does not open it" ;;
        *) restic_run cat config > /dev/null || true; die "restic cat config exited $rc" ;;
    esac
    restic_run snapshots --compact
}

cmd_status() {
    echo "--- secrets"
    ls -l --time-style=+%F\ %R "$SECRETS" 2>/dev/null | tail -n +2 || echo "  (none)"
    echo "--- dump secrets"
    ls -l --time-style=+%F\ %R "$DUMP_SECRETS" 2>/dev/null | tail -n +2 || echo "  (none)"
    echo "--- dumps"
    find "$DUMPS" -mindepth 2 -maxdepth 2 -type f -printf '  %TY-%Tm-%Td %TH:%TM  %10s  %p\n' 2>/dev/null | sort -k3
    if [ -d /srv/komodo/backups ]; then
        echo "--- komodo backups (newest 3)"
        ls -1t /srv/komodo/backups | head -3 | sed 's/^/  /'
        echo "  owner: $(stat -c %u:%g /srv/komodo/backups)"
    fi
    echo "--- snapshots (latest per host and path)"
    restic_run snapshots --compact --latest 1
    echo "--- repository size"
    restic_run stats --mode raw-data | grep -E 'Total (Blob|Uncompressed)|Total Size|Compression' || true
}

cmd_canary() {
    local server=${1:-}
    [[ $server =~ ^[a-z0-9-]+$ ]] || die "usage: canary <server>"
    local id
    id=$(restic_run backup --host "canary-$server" --tag canary --json /etc/os-release \
        | sed -n 's/.*"snapshot_id":"\([0-9a-f]*\)".*/\1/p')
    [ -n "$id" ] || die "canary backup failed"
    echo "canary snapshot ${id:0:8}; now forgetting it with this server's key"
    restic_run forget "$id"
    echo "restic no longer lists it:"
    restic_run snapshots --tag canary --compact
    echo
    echo "In the B2 web UI: bucket > Browse Files > $server/snapshots/, turn on"
    echo "'Show hidden files' (or file versions): $id must still be there,"
    echo "hidden. Unhide it there, and 'snapshots --tag canary' shows it again."
}

case ${1:-} in
    prep) shift; cmd_prep "$@" ;;
    pg-reader) shift; cmd_pg_reader "$@" ;;
    secret) shift; cmd_secret "$@" ;;
    init) cmd_init ;;
    status) cmd_status ;;
    canary) shift; cmd_canary "$@" ;;
    *) sed -n '2,19p' "$0"; exit 2 ;;
esac
