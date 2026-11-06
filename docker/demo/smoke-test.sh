#!/usr/bin/env bash
# Smoke test for the demo image: starts it under a non-default port and URL
# and checks that the installed shop really works.
#
#   docker/demo/smoke-test.sh <image> [port]
#
# Checks: the storefront answers, its links use the configured URL, the
# storefront search lists a real demo product (and not for a nonsense term),
# the admin login works with the configured credentials, rejects a wrong
# password and the shop's default admin/admin, the shop's logger writes its
# log, e-mail "sends" but is discarded, SMTP can't be enabled, and
# `docker stop` shuts MariaDB down cleanly. HTTPS mode (ports port+1 and
# port+2): https URLs without a public host name or with another port are
# refused; with a valid one, Apache speaks TLS on 443, redirects http to
# https (other host names to the shop URL, ACME challenges excepted), the
# shop gets the https URL, and a renewed certificate triggers a reload. It
# runs against a certificate authority that does not exist, so no
# certificate is issued and nothing is sent to Let's Encrypt. O3_HTTPS=proxy
# (port port+3): plain http with https links, no redirect loop, no TLS in
# the container.

set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image> [port]}"
PORT="${2:-8099}"
URL="http://localhost:$PORT"
ADMIN_EMAIL=smoke@example.com
ADMIN_PASSWORD=smoke-test-pw
NAME="o3-shop-demo-smoke-$$"
JAR="$(mktemp)"
HTTP_NAME="$NAME"
TLS_NAME="$NAME-https"
TLS_HOST=smoke.o3-shop.com
TLS_HTTP_PORT=$((PORT + 1))
TLS_HTTPS_PORT=$((PORT + 2))
PROXY_NAME="$NAME-proxy"
PROXY_PORT=$((PORT + 3))
ACME_CONF="$(mktemp)"

cleanup() {
    rm -f "$JAR" "$ACME_CONF"
    docker rm -f "$HTTP_NAME" "$TLS_NAME" "$PROXY_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
    echo "SMOKE TEST FAILED: $*" >&2
    docker logs "$NAME" 2>&1 | tail -30 >&2 || true
    exit 1
}

docker run -d --name "$NAME" -p "$PORT:80" \
    -e O3_SHOP_URL="$URL" \
    -e O3_ADMIN_EMAIL="$ADMIN_EMAIL" \
    -e O3_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    "$IMAGE" >/dev/null

echo "Waiting for the storefront at $URL ..."
home=""
for _ in $(seq 1 60); do
    if home="$(curl -fsS "$URL/" 2>/dev/null)"; then
        break
    fi
    sleep 2
done
[ -n "$home" ] || fail "storefront did not answer within 120 seconds"

grep -qF "src=\"$URL/out/" <<<"$home" \
    || fail "storefront does not use the configured URL $URL"

product="$(docker exec "$NAME" mariadb -uo3shop -po3shop o3shop -N -e \
    "SELECT OXTITLE FROM oxv_oxarticles_de WHERE OXACTIVE = 1 AND OXPARENTID = '' AND OXTITLE REGEXP '^[A-Za-z0-9 ]+$' ORDER BY OXTITLE LIMIT 1")" \
    || fail "could not read the demo products from the database"
[ -n "$product" ] || fail "no active demo product in the database"

# The search term is echoed in the page title and heading even without hits,
# so count result entries: the product title as link text or title attribute.
# Sets HITS. Runs in the main shell (no $(...)), so fail() ends the test.
search_hits() {
    local term="$1" title="$2" page
    page="$(curl -fsS -G "$URL/index.php" --data-urlencode "cl=search" --data-urlencode "searchparam=$term")" \
        || fail "storefront search request failed"
    HITS="$(grep -cF -e ">$title<" -e "title=\"$title" <<<"$page" || true)"
}
search_hits "$product" "$product"
[ "$HITS" -gt 0 ] || fail "storefront search does not list demo product '$product'"
search_hits "zz-no-such-product-zz" "$product"
[ "$HITS" -eq 0 ] || fail "storefront search lists '$product' for a nonsense term (hit check is not selective)"
echo "Storefront OK (search lists demo product '$product')."

# Sets LOGIN to "ok" when the admin login succeeds, "denied" otherwise.
admin_login() {
    local user="$1" password="$2" page action stoken sid result
    rm -f "$JAR"
    page="$(curl -fsS -c "$JAR" -b "$JAR" "$URL/admin/")" || fail "admin page request failed"
    action="$(grep -o 'form action="[^"]*"' <<<"$page" | head -1 | sed 's/^form action="//; s/"$//; s/&amp;/\&/g')"
    stoken="$(grep -o 'name="stoken" value="[^"]*"' <<<"$page" | sed 's/.*value="//; s/"$//')"
    sid="$(grep -o 'name="admin_sid" value="[^"]*"' <<<"$page" | sed 's/.*value="//; s/"$//')"
    [ -n "$action" ] && [ -n "$stoken" ] || fail "admin login form not found"
    result="$(curl -fsS -L -c "$JAR" -b "$JAR" \
        --data-urlencode "stoken=$stoken" --data-urlencode "admin_sid=$sid" \
        --data-urlencode "fnc=checklogin" --data-urlencode "cl=login" \
        --data-urlencode "user=$user" --data-urlencode "pwd=$password" \
        "$action")" || fail "admin login request failed"
    if grep -q 'cl=navigation' <<<"$result"; then LOGIN=ok; else LOGIN=denied; fi
}

admin_login "$ADMIN_EMAIL" "$ADMIN_PASSWORD"
[ "$LOGIN" = ok ] || fail "admin login with the configured credentials failed"
admin_login "$ADMIN_EMAIL" "wrong-$ADMIN_PASSWORD"
[ "$LOGIN" = denied ] || fail "admin login accepted a wrong password"
admin_login admin admin
[ "$LOGIN" = denied ] || fail "the shop's default login admin/admin is still active"
echo "Admin login OK."

# Runs PHP code inside the shop (as the web user), with the shop bootstrapped.
shop_php() {
    docker exec -u www-data -w /var/www/html "$NAME" php -r "require 'source/bootstrap.php'; $1"
}

# O3SHOP_CONF_LOG_DIR must resolve below the shop dir; a wrong path makes every
# log write throw, and the visitor gets the maintenance page (o3-shop#257).
shop_php '\OxidEsales\Eshop\Core\Registry::getLogger()->error("Smoke test - Checking that the shop log is writable.");' \
    || fail "the shop's logger failed"
docker exec "$NAME" grep -qF "Checking that the shop log is writable." /var/www/html/source/log/oxideshop.log \
    || fail "the shop's logger did not write source/log/oxideshop.log"
echo "Shop log OK."

# The demo sends no e-mail: mail() "succeeds" into mail-sink.sh, which only
# logs the recipient (o3-shop#258).
mail_out="$(shop_php 'exit(oxNew(\OxidEsales\Eshop\Core\Email::class)->sendEmail("smoke-recipient@example.com", "Smoke test", "Smoke test body.") ? 0 : 1);' 2>&1)" \
    || fail "the shop could not send an e-mail into the sink: $mail_out"
grep -qF "Discarded an outgoing e-mail to 'smoke-recipient@example.com'" <<<"$mail_out" \
    || fail "the e-mail did not go to mail-sink.sh: $mail_out"
smtp="$(docker exec "$NAME" mariadb -uo3shop -po3shop o3shop -N -e \
    "UPDATE oxshops SET OXSMTP = 'smtp.example.com:25', OXSMTPUSER = 'smoke', OXSMTPPWD = 'smoke'; SELECT CONCAT(OXSMTP, OXSMTPUSER, OXSMTPPWD) FROM oxshops")" \
    || fail "could not update the shop's SMTP settings"
[ -z "$(tr -d '[:space:]' <<<"$smtp")" ] || fail "SMTP settings could be set ('$smtp'); the demo could send real e-mail"
echo "E-mail OK (discarded, SMTP locked)."

# Default stop timeout, as users run it.
docker stop "$NAME" >/dev/null
logs="$(docker logs "$NAME" 2>&1)"
grep -qF "[o3-shop-demo] MariaDB stopped cleanly." <<<"$logs" \
    || fail "docker stop did not shut MariaDB down cleanly"
# MariaDB removes its pid file only on a clean shutdown.
if docker cp "$NAME:/run/mysqld/mysqld.pid" - >/dev/null 2>&1; then
    fail "MariaDB pid file still present after docker stop (unclean shutdown)"
fi
exit_code="$(docker inspect "$NAME" -f '{{.State.ExitCode}}')"
[ "$exit_code" = 0 ] || fail "container exited with $exit_code after docker stop"
echo "Clean stop OK."

# HTTPS mode (o3-shop#269). URLs Let's Encrypt or the redirect can't serve
# must stop the container at startup. Bounded wait, since an accepted URL
# keeps it running; no network, so it could not reach Let's Encrypt either.
# refuse_url <url> <expected message> [extra docker run arguments...]
refuse_url() {
    local url="$1" expected="$2" out
    shift 2
    docker run -d --name "$TLS_NAME" --network none -e O3_SHOP_URL="$url" "$@" "$IMAGE" >/dev/null
    for _ in $(seq 1 30); do
        [ "$(docker inspect "$TLS_NAME" -f '{{.State.Running}}')" = false ] && break
        sleep 1
    done
    [ "$(docker inspect "$TLS_NAME" -f '{{.State.Running}}')" = false ] \
        || fail "O3_SHOP_URL $url was accepted (container still running after 30 seconds)"
    out="$(docker logs "$TLS_NAME" 2>&1)"
    [ "$(docker inspect "$TLS_NAME" -f '{{.State.ExitCode}}')" != 0 ] \
        || fail "O3_SHOP_URL $url was refused with exit code 0: $out"
    grep -qF "$expected" <<<"$out" || fail "O3_SHOP_URL $url was refused without '$expected': $out"
    docker rm -f "$TLS_NAME" >/dev/null
}
NAME="$TLS_NAME"  # fail() shows the https containers' log from here on
refuse_url "https://localhost" "https needs a public host name"
refuse_url "https://192.0.2.10" "https needs a public host name"
refuse_url "https://shop.o3-demo.test" "https needs a public host name"
refuse_url "https://demo.example.com" "https needs a public host name"
refuse_url "https://$TLS_HOST:8443" "https works only on the standard port 443"
refuse_url "https://$TLS_HOST:80:443" "https works only on the standard port 443"
# These values end up in the Apache configuration.
refuse_url "https://$TLS_HOST" "O3_ACME_EMAIL" -e "O3_ACME_EMAIL=ops@o3-shop.com
Include /etc/shadow"
refuse_url "https://$TLS_HOST" "O3_ACME_STAGING must be 0 or 1" -e O3_ACME_STAGING=yes
refuse_url "https://$TLS_HOST" "O3_HTTPS must be letsencrypt or proxy" -e O3_HTTPS=nginx

# O3_ACME_EMAIL and O3_ACME_STAGING reach mod_md's configuration (checked
# offline: nothing is started).
md_conf="$(docker run --rm --network none --entrypoint bash \
    -e O3_SHOP_URL="https://$TLS_HOST" -e O3_ACME_EMAIL=ops@o3-shop.com -e O3_ACME_STAGING=1 "$IMAGE" \
    -c 'source /usr/local/bin/entrypoint.sh && validate_env && configure_https && cat /etc/apache2/sites-enabled/o3-shop-https.conf')" \
    || fail "could not generate the https configuration"
grep -qxF "MDContactEmail ops@o3-shop.com" <<<"$md_conf" || fail "O3_ACME_EMAIL does not reach mod_md: $md_conf"
grep -qxF "MDCertificateAuthority https://acme-staging-v02.api.letsencrypt.org/directory" <<<"$md_conf" \
    || fail "O3_ACME_STAGING=1 does not select the staging CA: $md_conf"

# mod_md must not reach a real certificate authority from the smoke test:
# Let's Encrypt's host names resolve to nothing here, and mod_md is pointed
# at a CA that does not exist. The CA setting is copied in, not
# bind-mounted: a bind mount Docker cannot share turns into an empty
# directory, which Apache skips.
DEAD_CA=http://127.0.0.1:9/directory
printf '<IfModule md_module>\n    MDCertificateAuthority %s\n</IfModule>\n' "$DEAD_CA" > "$ACME_CONF"
docker create --name "$TLS_NAME" -p "$TLS_HTTP_PORT:80" -p "$TLS_HTTPS_PORT:443" \
    --add-host acme-v02.api.letsencrypt.org:127.0.0.1 \
    --add-host acme-staging-v02.api.letsencrypt.org:127.0.0.1 \
    -e O3_SHOP_URL="https://$TLS_HOST" \
    "$IMAGE" >/dev/null || fail "could not create the https container"
docker cp "$ACME_CONF" "$TLS_NAME:/etc/apache2/conf-enabled/zz-smoke-acme.conf" \
    || fail "could not copy the test CA configuration into the https container"
docker start "$TLS_NAME" >/dev/null || fail "could not start the https container"

# The shop URL has the standard ports; curl sends that host name but
# connects to the published test ports.
tls_curl() {
    curl -s --max-time 10 --connect-to "$TLS_HOST:80:127.0.0.1:$TLS_HTTP_PORT" \
        --connect-to "$TLS_HOST:443:127.0.0.1:$TLS_HTTPS_PORT" "$@"
}

code=""
for _ in $(seq 1 60); do
    # -k: there is no certificate yet; mod_md answers 503 until it has one.
    code="$(tls_curl -k -o /dev/null -w '%{http_code}' "https://$TLS_HOST/" 2>/dev/null || true)"
    [ "$code" = 503 ] && break
    sleep 2
done
[ "$code" = 503 ] || fail "https did not answer 503 (no certificate yet) within 120 seconds, got '$code'"

# Proves the test CA is in effect: mod_md reports it cannot reach it.
ca_logged=""
for _ in $(seq 1 30); do
    logs="$(docker logs "$TLS_NAME" 2>&1)"
    if grep -qF "$DEAD_CA" <<<"$logs"; then ca_logged=yes; break; fi
    sleep 2
done
[ -n "$ca_logged" ] || fail "mod_md never tried the test CA $DEAD_CA; it may be using a real one"
! grep -qi "letsencrypt.org" <<<"$logs" || fail "mod_md tried to contact Let's Encrypt during the smoke test"

redirect="$(tls_curl -o /dev/null -w '%{http_code} %{redirect_url}' "http://$TLS_HOST/index.php?cl=search")" \
    || fail "http request in https mode failed"
[ "$redirect" = "302 https://$TLS_HOST/index.php?cl=search" ] || fail "http is not redirected to https: '$redirect'"
other="$(curl -s --max-time 10 -o /dev/null -w '%{http_code} %{redirect_url}' "http://127.0.0.1:$TLS_HTTP_PORT/index.php?cl=search")" \
    || fail "http request by IP address in https mode failed"
[ "$other" = "302 https://$TLS_HOST/index.php?cl=search" ] \
    || fail "http by IP address is not redirected to the shop URL: '$other'"
challenge="$(tls_curl -o /dev/null -w '%{http_code}' "http://$TLS_HOST/.well-known/acme-challenge/smoke-test")" \
    || fail "ACME challenge request failed"
[ "$challenge" = 404 ] || fail "ACME challenges are not answered by mod_md over http (got '$challenge'); Let's Encrypt could not validate the host"
other_tls="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code} %{redirect_url}' "https://127.0.0.1:$TLS_HTTPS_PORT/index.php?cl=search")" \
    || fail "https request by IP address failed"
[ "$other_tls" = "302 https://$TLS_HOST/index.php?cl=search" ] \
    || fail "https by IP address is not redirected to the shop URL: '$other_tls'"
docker exec "$TLS_NAME" grep -qxF "O3SHOP_CONF_SSLSHOPURL=https://$TLS_HOST/" /var/www/html/.env \
    || fail "the shop's SSL URL is not https://$TLS_HOST/"
shop_urls="$(shop_php '$c = \OxidEsales\Eshop\Core\Registry::getConfig(); echo $c->getShopUrl(), " ", $c->getSslShopUrl();')" \
    || fail "could not read the shop URLs"
[ "$shop_urls" = "https://$TLS_HOST/ https://$TLS_HOST/" ] \
    || fail "the shop does not build its links with https://$TLS_HOST/: '$shop_urls'"

# mod_md reports the failed attempt (the test CA does not exist) through
# MDMessageCmd; the entrypoint logs it.
errored=""
for _ in $(seq 1 30); do
    logs="$(docker logs "$TLS_NAME" 2>&1)"
    if grep -qF "Let's Encrypt could not issue the certificate for $TLS_HOST" <<<"$logs"; then errored=yes; break; fi
    sleep 2
done
[ -n "$errored" ] || fail "a failed certificate attempt was not reported in the log"

# A certificate mod_md reports as renewed gets activated by a graceful
# reload: Apache logs "resuming normal operations" (AH00163) once more.
starts="$(docker logs "$TLS_NAME" 2>&1 | grep -c AH00163 || true)"
docker exec -u www-data "$TLS_NAME" /usr/local/bin/md-message.sh renewed "$TLS_HOST" \
    || fail "md-message.sh failed"
reloaded=""
for _ in $(seq 1 15); do
    logs="$(docker logs "$TLS_NAME" 2>&1)"
    if [ "$(grep -c AH00163 <<<"$logs" || true)" -gt "$starts" ]; then reloaded=yes; break; fi
    sleep 2
done
[ -n "$reloaded" ] || fail "a renewed certificate did not trigger a graceful Apache reload"
! grep -qF "Reloading Apache failed" <<<"$logs" || fail "reloading Apache failed"
code="$(tls_curl -k -o /dev/null -w '%{http_code}' "https://$TLS_HOST/" || true)"
[ "$code" = 503 ] || fail "https stopped answering after the reload (got '$code')"

docker stop "$TLS_NAME" >/dev/null
grep -qF "[o3-shop-demo] MariaDB stopped cleanly." <<<"$(docker logs "$TLS_NAME" 2>&1)" \
    || fail "docker stop did not shut MariaDB down cleanly in https mode"
exit_code="$(docker inspect "$TLS_NAME" -f '{{.State.ExitCode}}')"
[ "$exit_code" = 0 ] || fail "https container exited with $exit_code after docker stop"
echo "HTTPS mode OK (bad URLs refused, TLS on 443, redirects, ACME challenge path, shop SSL URL, reload on renewal)."

# O3_HTTPS=proxy: a reverse proxy terminates TLS (here: no proxy, the test
# plays it and talks plain http to port 80). localhost and a port are fine.
# Let's Encrypt's host names are pinned anyway, in case mod_md got enabled.
proxy_url="https://localhost:$PROXY_PORT"
docker run -d --name "$PROXY_NAME" -p "$PROXY_PORT:80" \
    --add-host acme-v02.api.letsencrypt.org:127.0.0.1 \
    --add-host acme-staging-v02.api.letsencrypt.org:127.0.0.1 \
    -e O3_SHOP_URL="$proxy_url" -e O3_HTTPS=proxy "$IMAGE" >/dev/null
NAME="$PROXY_NAME"
page=""
for _ in $(seq 1 60); do
    if page="$(curl -fsS --max-time 10 "http://localhost:$PROXY_PORT/" 2>/dev/null)"; then break; fi
    page=""
    sleep 2
done
[ -n "$page" ] || fail "proxy mode: the shop did not answer plain http within 120 seconds"
# Links come from the shop URL in .env.
grep -qF "src=\"$proxy_url/out/" <<<"$page" || fail "proxy mode: the shop does not build its links with $proxy_url"
# The shop treats the request as https: its cookies carry the Secure flag.
headers="$(curl -sS --max-time 10 -D - -o /dev/null "http://localhost:$PROXY_PORT/")" || fail "proxy mode: request failed"
grep -qiE '^set-cookie:.*;[[:space:]]*secure' <<<"$headers" \
    || fail "proxy mode: the shop does not treat requests as https (no Secure cookie): $headers"
# The shop sends an autologin visitor to its SSL URL unless it sees an https
# request; behind the proxy that must not redirect (it would loop).
autologin="$(curl -s --max-time 10 -o /dev/null -w '%{http_code} %{redirect_url}' \
    -b "oxid_1_autologin=1" "http://localhost:$PROXY_PORT/index.php?cl=search")" || fail "proxy mode: request failed"
[ "$autologin" = "200 " ] || fail "proxy mode: the shop redirects a request the proxy received over https: '$autologin'"
if docker exec "$PROXY_NAME" apache2ctl -M 2>/dev/null | grep -qE "md_module|ssl_module"; then
    fail "proxy mode: mod_md/mod_ssl are enabled; the container must not terminate TLS"
fi
docker stop "$PROXY_NAME" >/dev/null
[ "$(docker inspect "$PROXY_NAME" -f '{{.State.ExitCode}}')" = 0 ] || fail "proxy mode: container did not stop cleanly"
echo "Proxy mode OK (plain http, https links, requests treated as https: Secure cookies, no redirect loop; no TLS in the container)."

echo "Smoke test passed."
