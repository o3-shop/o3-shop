#!/usr/bin/env bash
# Starts MariaDB, points the shop at the URL it is reached under and applies
# the admin login, then runs the main command (Apache). On `docker stop` it
# stops Apache and shuts MariaDB down cleanly.
#
# Environment:
#   O3_SHOP_URL        URL the shop is reached under (default http://localhost:8080)
#   O3_ADMIN_EMAIL     admin login (default admin@example.com)
#   O3_ADMIN_PASSWORD  admin password (default admin123)
#
# install.sh sources this file for its helpers; main() only runs when the
# file is executed.

set -euo pipefail

SHOP_ROOT=/var/www/html
DB_NAME=o3shop
DB_USER=o3shop
DB_PWD=o3shop
# The shop's own default admin (seeded by the shop data as "admin" / "admin").
# It is reused, so no other admin login exists.
ADMIN_OXID=oxdefaultadmin

log() {
    echo "[o3-shop-demo] $*"
}

die() {
    log "$*" >&2
    exit 1
}

# Values end up in .env (one KEY=value per line), so reject anything that
# could break or extend it.
validate_env() {
    local url="${O3_SHOP_URL:-http://localhost:8080}"
    local email="${O3_ADMIN_EMAIL:-admin@example.com}"
    local url_pattern='^https?://[][A-Za-z0-9.:_~/-]+$'
    local email_pattern='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$'
    [[ "$url" =~ $url_pattern ]] \
        || die "O3_SHOP_URL '$url' is not a plain http(s) URL (letters, digits and . : _ ~ / - [ ] only)."
    [[ "$email" =~ $email_pattern ]] \
        || die "O3_ADMIN_EMAIL '$email' is not a plain e-mail address."
    [[ -n "${O3_ADMIN_PASSWORD-admin123}" ]] || die "O3_ADMIN_PASSWORD must not be empty."
}

MARIADB_PIDFILE=/run/mysqld/mysqld.pid
# mariadbd-safe watches mariadbd and restarts it after a crash; it exits
# only once the server has shut down. Tracking it (not mariadbd) also covers
# a server restarted under a new pid.
MARIADB_SAFE_PID=""

start_mariadb() {
    mkdir -p /run/mysqld
    chown mysql:mysql /run/mysqld
    # In a non-interactive shell setsid does not fork, so $! is mariadbd-safe.
    setsid mariadbd-safe --user=mysql >/dev/null 2>&1 < /dev/null &
    MARIADB_SAFE_PID=$!
    for _ in $(seq 1 60); do
        if mariadb-admin ping --silent >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$MARIADB_SAFE_PID" 2>/dev/null || die "MariaDB failed to start."
        sleep 1
    done
    die "MariaDB did not start within 60 seconds."
}

# True while the process runs (a zombie, i.e. exited but not yet reaped,
# does not count).
alive() {
    [ -r "/proc/$1/stat" ] && ! grep -q ') Z ' "/proc/$1/stat" 2>/dev/null
}

# Shuts MariaDB down and waits until it is gone, whoever started the
# shutdown (Apache's stop can reach it, too). MariaDB removes its pid file
# only at the end of a clean shutdown.
stop_mariadb() {
    [ -n "$MARIADB_SAFE_PID" ] || return 0
    local safe_pid="$MARIADB_SAFE_PID" pid
    MARIADB_SAFE_PID=""
    # SIGTERM is mariadbd's normal shutdown and, unlike mariadb-admin, also
    # works while the server is starting or recovering. Re-read the pid file
    # each round: mariadbd-safe may have restarted a crashed server under a
    # new pid. mariadbd-safe exits once the server is gone.
    for _ in $(seq 1 120); do
        alive "$safe_pid" || break
        pid="$(cat "$MARIADB_PIDFILE" 2>/dev/null || true)"
        if [ -n "$pid" ]; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
        sleep 1
    done
    alive "$safe_pid" && die "MariaDB did not stop within 120 seconds."
    wait "$safe_pid" 2>/dev/null || true
    [ -e "$MARIADB_PIDFILE" ] && die "MariaDB exited without removing its pid file (unclean shutdown)."
    log "MariaDB stopped cleanly."
}

# config.inc.php reads its settings from the project root .env (Dotenv).
write_env() {
    local shop_url="${1%/}/"
    cat > "$SHOP_ROOT/.env" <<EOF
O3SHOP_CONF_DBHOST=127.0.0.1
O3SHOP_CONF_DBPORT=3306
O3SHOP_CONF_DBNAME=$DB_NAME
O3SHOP_CONF_DBUSER=$DB_USER
O3SHOP_CONF_DBPWD=$DB_PWD
O3SHOP_CONF_SHOPURL=$shop_url
O3SHOP_CONF_SSLSHOPURL=
O3SHOP_CONF_ADMINSSLURL=
O3SHOP_CONF_SHOPDIR=$SHOP_ROOT/source/
O3SHOP_CONF_COMPILEDIR=$SHOP_ROOT/source/tmp/
O3SHOP_CONF_LOG_DIR=$SHOP_ROOT/source/log/
O3SHOP_CONF_LOG_LEVEL=error
O3SHOP_CONF_DEBUG=0
O3SHOP_CONF_SKIPVIEWUSAGE=0
O3SHOP_CONF_DELSETUPDIR=1
O3SHOP_CONF_ADMINEMAIL=${O3_ADMIN_EMAIL:-admin@example.com}
EOF
    # Read-only for the shop; only this script writes it.
    chown root:www-data "$SHOP_ROOT/.env"
    chmod 640 "$SHOP_ROOT/.env"
}

# Sets login and password of the shop's default admin. Values reach PHP
# through the environment, never through the SQL text.
apply_admin() {
    ADMIN_EMAIL="${O3_ADMIN_EMAIL:-admin@example.com}" \
    ADMIN_PASSWORD="${O3_ADMIN_PASSWORD-admin123}" \
    ADMIN_OXID="$ADMIN_OXID" DB_NAME="$DB_NAME" DB_USER="$DB_USER" DB_PWD="$DB_PWD" \
    php -r '
        mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
        $db = new mysqli("127.0.0.1", getenv("DB_USER"), getenv("DB_PWD"), getenv("DB_NAME"), 3306);
        $id = getenv("ADMIN_OXID");
        $email = getenv("ADMIN_EMAIL");

        // OXUSERNAME is unique per shop: never take over another user.
        $check = $db->prepare("SELECT OXID FROM oxuser WHERE OXUSERNAME = ? AND OXID <> ?");
        $check->bind_param("ss", $email, $id);
        $check->execute();
        if ($check->get_result()->num_rows > 0) {
            fwrite(STDERR, "O3_ADMIN_EMAIL belongs to another user; choose a different one." . PHP_EOL);
            exit(1);
        }

        $hash = password_hash(getenv("ADMIN_PASSWORD"), PASSWORD_BCRYPT);
        $stmt = $db->prepare(
            "INSERT INTO oxuser (OXID, OXUSERNAME, OXPASSWORD, OXPASSSALT, OXACTIVE, OXRIGHTS, OXFNAME, OXLNAME, OXSHOPID)
             VALUES (?, ?, ?, \"\", 1, \"malladmin\", \"Admin\", \"User\", 1)
             ON DUPLICATE KEY UPDATE OXUSERNAME = VALUES(OXUSERNAME), OXPASSWORD = VALUES(OXPASSWORD),
                 OXPASSSALT = \"\", OXACTIVE = 1, OXRIGHTS = \"malladmin\""
        );
        $stmt->bind_param("sss", $id, $email, $hash);
        $stmt->execute();
    '
}

main() {
    # Trap stop signals from the start, also while MariaDB is starting.
    local child="" stop_requested=0
    trap 'stop_requested=1; if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || true; fi' TERM INT

    validate_env
    start_mariadb
    # Whatever ends this script from here on (a failed step included), shut
    # MariaDB down cleanly first; stop_mariadb is a no-op once it has run.
    trap 'stop_mariadb || true' EXIT
    write_env "${O3_SHOP_URL:-http://localhost:8080}"
    apply_admin
    # Smarty caches compiled templates with absolute URLs; start clean.
    find "$SHOP_ROOT/source/tmp" -mindepth 1 -maxdepth 1 ! -name '.htaccess' -exec rm -rf {} +

    local status=0
    if [ "$stop_requested" -eq 0 ]; then
        log "Shop: ${O3_SHOP_URL:-http://localhost:8080} (admin: ${O3_ADMIN_EMAIL:-admin@example.com}). Demo only, not for production."
        if [ "${O3_ADMIN_PASSWORD-admin123}" = admin123 ]; then
            log "WARNING: the admin uses the default password; set O3_ADMIN_PASSWORD for anything reachable by others."
        fi
        # Apache runs as a child, so a stop signal can also shut MariaDB down.
        "$@" &
        child=$!
        # A stop that arrived between the check above and $! found no child.
        if [ "$stop_requested" -eq 1 ]; then kill -TERM "$child" 2>/dev/null || true; fi
        # Returns when Apache or MariaDB ends, or when a signal arrives.
        # wait -n ignores an already reaped pid, so check MariaDB first.
        if alive "$MARIADB_SAFE_PID"; then
            wait -n "$child" "$MARIADB_SAFE_PID" || status=$?
        fi
        if [ "$stop_requested" -eq 0 ] && ! alive "$MARIADB_SAFE_PID"; then
            log "MariaDB ended unexpectedly; stopping the container."
            status=1
        fi
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    # A requested stop is a normal end.
    [ "$stop_requested" -eq 1 ] && status=0
    log "Stopping MariaDB."
    stop_mariadb
    trap - EXIT
    exit "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
