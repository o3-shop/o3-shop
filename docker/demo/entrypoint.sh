#!/usr/bin/env bash
# Starts MariaDB, points the shop at the URL it is reached under, locks the
# shop's SMTP settings (the demo sends no e-mail) and applies the admin login,
# then runs the main command (Apache). With an https URL, Apache serves the
# shop over TLS with a Let's Encrypt certificate (mod_md). On `docker stop` it
# stops Apache and shuts MariaDB down cleanly.
#
# Environment:
#   O3_SHOP_URL        URL the shop is reached under (default http://localhost:8080)
#   O3_ADMIN_EMAIL     admin login (default admin@example.com)
#   O3_ADMIN_PASSWORD  admin password (default admin123)
#   O3_ACME_EMAIL      https only: contact address for the certificate (optional)
#   O3_ACME_STAGING    https only: 1 = Let's Encrypt staging CA, for testing (default 0)
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
# Apache site for https mode, written at container start.
HTTPS_SITE=o3-shop-https
# md-message.sh (run by mod_md as the web user) leaves these markers; the
# entrypoint logs and acts on them, since the script's own output never
# reaches `docker logs`.
CERT_MARKER_DIR=/run/o3-shop-demo
LETSENCRYPT_STAGING=https://acme-staging-v02.api.letsencrypt.org/directory

log() {
    echo "[o3-shop-demo] $*"
}

die() {
    log "$*" >&2
    exit 1
}

# Prints the host name of an https URL (lower case, without port and path);
# prints nothing for an http URL.
https_domain() {
    local url="$1" host
    [[ "$url" == https://* ]] || return 0
    host="${url#https://}"
    host="${host%%/*}"
    # An IPv6 literal ([::1]:8443) keeps its brackets; the check rejects it.
    [[ "$host" == \[* ]] || host="${host%%:*}"
    printf '%s' "${host,,}"
}

# Values end up in .env (one KEY=value per line) and, in https mode, in the
# Apache configuration, so reject anything that could break or extend them.
validate_env() {
    local url="${O3_SHOP_URL:-http://localhost:8080}"
    local email="${O3_ADMIN_EMAIL:-admin@example.com}"
    local url_pattern='^https?://[][A-Za-z0-9.:_~/-]+$'
    local email_pattern='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$'
    # A public DNS name: Let's Encrypt issues no certificates for localhost,
    # IP addresses, single-label names or reserved names (.test, .local, ...).
    local domain_pattern='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'
    local reserved_pattern='(\.(test|example|invalid|localhost|local|internal|lan|home|corp|onion|arpa)|^example\.(com|net|org))$'
    [[ "$url" =~ $url_pattern ]] \
        || die "O3_SHOP_URL '$url' is not a plain http(s) URL (letters, digits and . : _ ~ / - [ ] only)."
    [[ "$email" =~ $email_pattern ]] \
        || die "O3_ADMIN_EMAIL '$email' is not a plain e-mail address."
    [[ -n "${O3_ADMIN_PASSWORD-admin123}" ]] || die "O3_ADMIN_PASSWORD must not be empty."

    [[ "$url" == https://* ]] || return 0
    local domain host_port
    domain="$(https_domain "$url")"
    [[ "$domain" =~ $domain_pattern && ! "$domain" =~ $reserved_pattern && ${#domain} -le 253 ]] \
        || die "O3_SHOP_URL '$url': https needs a public host name for the Let's Encrypt certificate, not '$domain' (no localhost, IP address, reserved name or name without a dot). Use an http URL for local tests."
    # Let's Encrypt checks the host on port 80 and the http redirect goes to
    # port 443, so the shop must be reached on the standard https port.
    host_port="${url#https://}"
    host_port="${host_port%%/*}"
    [[ "$host_port" =~ ^[^:]+(:443)?$ ]] \
        || die "O3_SHOP_URL '$url': https works only on the standard port 443 (publish it with -p 443:443, and port 80 with -p 80:80)."
    if [[ -n "${O3_ACME_EMAIL:-}" ]]; then
        [[ "$O3_ACME_EMAIL" =~ $email_pattern ]] \
            || die "O3_ACME_EMAIL '$O3_ACME_EMAIL' is not a plain e-mail address."
    fi
    [[ "${O3_ACME_STAGING:-0}" =~ ^[01]$ ]] || die "O3_ACME_STAGING must be 0 or 1, not '$O3_ACME_STAGING'."
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
# O3SHOP_CONF_LOG_DIR is relative to O3SHOP_CONF_SHOPDIR (Config::getLogsDir()
# prepends the shop dir); an absolute path makes every log write fail.
write_env() {
    local shop_url="${1%/}/" ssl_shop_url=""
    # https only: the shop builds every link with https.
    [[ "$shop_url" == https://* ]] && ssl_shop_url="$shop_url"
    cat > "$SHOP_ROOT/.env" <<EOF
O3SHOP_CONF_DBHOST=127.0.0.1
O3SHOP_CONF_DBPORT=3306
O3SHOP_CONF_DBNAME=$DB_NAME
O3SHOP_CONF_DBUSER=$DB_USER
O3SHOP_CONF_DBPWD=$DB_PWD
O3SHOP_CONF_SHOPURL=$shop_url
O3SHOP_CONF_SSLSHOPURL=$ssl_shop_url
O3SHOP_CONF_ADMINSSLURL=
O3SHOP_CONF_SHOPDIR=$SHOP_ROOT/source/
O3SHOP_CONF_COMPILEDIR=$SHOP_ROOT/source/tmp/
O3SHOP_CONF_LOG_DIR=log/
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

# With an https shop URL, lets Apache (mod_md) obtain and renew a Let's Encrypt
# certificate for its host and serve the shop over TLS; http requests are
# redirected to https, except mod_md's own ACME challenges, and requests for
# any other host name (IP address, aliases) to the shop URL. With an http URL,
# switches all of that off again. Certificates live in /etc/apache2/md.
configure_https() {
    local domain
    domain="$(https_domain "${O3_SHOP_URL:-http://localhost:8080}")"
    if [ -z "$domain" ]; then
        a2dissite -q "$HTTPS_SITE" >/dev/null 2>&1 || true
        a2dismod -q -f md ssl >/dev/null 2>&1 || true
        rm -f "/etc/apache2/sites-available/$HTTPS_SITE.conf"
        a2ensite -q 000-default >/dev/null
        return 0
    fi

    {
        echo "# Written by entrypoint.sh at container start: O3_SHOP_URL is https."
        echo "MDCertificateAgreement accepted"
        if [ -n "${O3_ACME_EMAIL:-}" ]; then
            echo "MDContactEmail $O3_ACME_EMAIL"
        fi
        if [ "${O3_ACME_STAGING:-0}" = 1 ]; then
            echo "MDCertificateAuthority $LETSENCRYPT_STAGING"
        fi
        # temporary = 302 without HSTS: the host may serve plain http again later.
        echo "MDRequireHttps temporary"
        echo "MDMessageCmd /usr/local/bin/md-message.sh"
        echo "MDomain $domain"
        echo
        echo "# First vhost = default: any other host name goes to the shop URL."
        echo "<VirtualHost *:80>"
        echo "    ServerName o3-shop-demo.invalid"
        echo "    Redirect 302 / https://$domain/"
        echo "</VirtualHost>"
        echo "<VirtualHost *:80>"
        echo "    ServerName $domain"
        echo "    DocumentRoot $SHOP_ROOT/source"
        echo "</VirtualHost>"
        echo "<VirtualHost *:443>"
        echo "    ServerName $domain"
        echo "    DocumentRoot $SHOP_ROOT/source"
        echo "    SSLEngine on"
        echo "    # Other host names (IP address, aliases) go to the shop URL."
        echo "    RewriteEngine on"
        echo "    RewriteCond %{HTTP_HOST} !^${domain//./\\.}(:443)?\$ [NC]"
        echo "    RewriteRule ^ https://$domain%{REQUEST_URI} [R=302,L]"
        echo "</VirtualHost>"
    } > "/etc/apache2/sites-available/$HTTPS_SITE.conf"
    a2enmod -q ssl md >/dev/null
    a2dissite -q 000-default >/dev/null
    a2ensite -q "$HTTPS_SITE" >/dev/null

    # md-message.sh runs as the web user.
    mkdir -p "$CERT_MARKER_DIR"
    chown www-data:www-data "$CERT_MARKER_DIR"
    rm -f "$CERT_MARKER_DIR/renewed" "$CERT_MARKER_DIR/errored"
}

# Acts on what mod_md reported through md-message.sh: a new certificate (the
# first one, or a renewal) waits until Apache reloads, so reload gracefully;
# a failed attempt gets a log line (mod_md retries on its own).
watch_certificates() {
    local domain
    domain="$(https_domain "$O3_SHOP_URL")"
    while sleep 10; do
        if [ -e "$CERT_MARKER_DIR/errored" ]; then
            rm -f "$CERT_MARKER_DIR/errored"
            log "Let's Encrypt could not issue the certificate for $domain; the mod_md errors above name the cause (host name not pointing here, ports 80/443 not reachable, rate limit). Apache retries automatically."
        fi
        if [ -e "$CERT_MARKER_DIR/renewed" ]; then
            rm -f "$CERT_MARKER_DIR/renewed"
            log "New certificate for $domain; reloading Apache to activate it."
            apache2ctl -k graceful || log "Reloading Apache failed; the new certificate is used after the next restart."
        fi
    done
}

# The demo never sends e-mail: mail() goes to mail-sink.sh (php.ini
# sendmail_path), and these triggers keep the shop's SMTP settings empty, so
# setting an SMTP server in the admin (whose login is public) has no effect.
# Runs on every start, so databases in volumes from older images get them too.
lock_smtp() {
    mariadb -uroot "$DB_NAME" <<'SQL'
CREATE OR REPLACE TRIGGER o3_demo_no_smtp_insert BEFORE INSERT ON oxshops FOR EACH ROW
    SET NEW.OXSMTP = '', NEW.OXSMTPUSER = '', NEW.OXSMTPPWD = '';
CREATE OR REPLACE TRIGGER o3_demo_no_smtp_update BEFORE UPDATE ON oxshops FOR EACH ROW
    SET NEW.OXSMTP = '', NEW.OXSMTPUSER = '', NEW.OXSMTPPWD = '';
UPDATE oxshops SET OXSMTP = '', OXSMTPUSER = '', OXSMTPPWD = '';
SQL
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
    local child="" watcher="" stop_requested=0
    trap 'stop_requested=1; if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || true; fi' TERM INT

    validate_env
    start_mariadb
    # Whatever ends this script from here on (a failed step included), shut
    # MariaDB down cleanly first; stop_mariadb is a no-op once it has run.
    trap 'stop_mariadb || true' EXIT
    write_env "${O3_SHOP_URL:-http://localhost:8080}"
    configure_https
    lock_smtp
    apply_admin
    # Smarty caches compiled templates with absolute URLs; start clean.
    find "$SHOP_ROOT/source/tmp" -mindepth 1 -maxdepth 1 ! -name '.htaccess' -exec rm -rf {} +

    local status=0
    if [ "$stop_requested" -eq 0 ]; then
        log "Shop: ${O3_SHOP_URL:-http://localhost:8080} (admin: ${O3_ADMIN_EMAIL:-admin@example.com}). Demo only, not for production."
        if [ "${O3_ADMIN_PASSWORD-admin123}" = admin123 ]; then
            log "WARNING: the admin uses the default password; set O3_ADMIN_PASSWORD for anything reachable by others."
        fi
        if [ -n "$(https_domain "${O3_SHOP_URL:-http://localhost:8080}")" ]; then
            log "HTTPS: Apache obtains a Let's Encrypt certificate for $(https_domain "$O3_SHOP_URL") (ports 80 and 443 must be reachable from the internet). Until it is active, https requests for that host get 503."
            watch_certificates &
            watcher=$!
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
        if [ -n "$watcher" ]; then
            kill "$watcher" 2>/dev/null || true
            wait "$watcher" 2>/dev/null || true
        fi
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
