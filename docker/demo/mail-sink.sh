#!/bin/sh
# PHP's sendmail_path in the demo image: reads the message PHP's mail() hands
# over and discards it, so the shop's mails "succeed" and go nowhere. The demo
# is public and its admin login documented; it must never send real e-mail.
# Logs one line per mail (to Apache's error log, i.e. `docker logs`). PHP
# appends sendmail options such as -f<sender>; they are ignored.

to="$(sed -n '/^\r\{0,1\}$/q; s/^To: *//p' | head -n 1 | tr -d '\r\n')"
cat > /dev/null
echo "[o3-shop-demo] Discarded an outgoing e-mail to '$to'. The demo image sends no e-mail." >&2
exit 0
