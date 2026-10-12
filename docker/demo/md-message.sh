#!/bin/sh
# Called by mod_md (MDMessageCmd) as the web user: md-message.sh <event> <domain>.
# Its output does not reach `docker logs`, so it only leaves a marker for
# entrypoint.sh (watch_certificates), which logs it and, on "renewed", reloads
# Apache: a new certificate waits in mod_md's staging area until then.
# A non-zero exit makes mod_md log an error.
case "$1" in
    renewed|errored) touch "/run/o3-shop-demo/$1" || exit 1 ;;
esac
exit 0
