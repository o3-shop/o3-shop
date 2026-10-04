#!/usr/bin/env bash
# Smoke test for the demo image: starts it under a non-default port and URL
# and checks that the installed shop really works.
#
#   docker/demo/smoke-test.sh <image> [port]
#
# Checks: the storefront answers, its links use the configured URL, the
# storefront search lists a real demo product (and not for a nonsense term),
# the admin login works with the configured credentials, rejects a wrong
# password and the shop's default admin/admin, and `docker stop` shuts
# MariaDB down cleanly.

set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image> [port]}"
PORT="${2:-8099}"
URL="http://localhost:$PORT"
ADMIN_EMAIL=smoke@example.com
ADMIN_PASSWORD=smoke-test-pw
NAME="o3-shop-demo-smoke-$$"
JAR="$(mktemp)"

cleanup() {
    rm -f "$JAR"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
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

echo "Smoke test passed."
