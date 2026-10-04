#!/usr/bin/env bash
# Build-time install of the demo shop: database, schema, migrations, demo
# data, admin, theme and views. Runs once during `docker build`; the
# resulting database is part of the image.

set -euo pipefail

# shellcheck source=entrypoint.sh
source /usr/local/bin/entrypoint.sh

SQL_DIR="$SHOP_ROOT/source/Setup/Sql"
cd "$SHOP_ROOT"

log "Starting MariaDB for the install."
start_mariadb

log "Creating database '$DB_NAME' and user '$DB_USER'."
mariadb -uroot <<SQL
CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PWD';
CREATE USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PWD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

write_env "http://localhost:8080"

db() {
    mariadb --default-character-set=utf8mb4 -h127.0.0.1 -u"$DB_USER" -p"$DB_PWD" "$DB_NAME"
}

log "Importing the database schema."
db < "$SQL_DIR/database_schema.sql"

log "Running database migrations."
php vendor/bin/oe-eshop-doctrine_migration migrations:migrate

log "Installing demo data (pictures and SQL)."
php vendor/bin/oe-eshop-demodata_install
db < vendor/o3-shop/shop-demodata-ce/src/demodata.sql

# Same as the shop's own setup: initial_data.sql fills what demodata.sql
# does not seed (e.g. theme settings); demo rows win on shared IDs.
log "Backfilling initial data."
sed 's/INSERT INTO/INSERT IGNORE INTO/g' "$SQL_DIR/initial_data.sql" | db

log "Setting the admin login."
apply_admin

log "Activating the default theme."
php vendor/bin/oe-console oe:theme:activate

log "Generating database views."
php vendor/bin/oe-eshop-db_views_generate

# The web setup wizard is not needed (and must not be reachable) once the
# shop is installed.
rm -rf "$SHOP_ROOT/source/Setup"

chown -R www-data:www-data "$SHOP_ROOT/source" "$SHOP_ROOT/var"
# The php base image ships /var/www/html world-writable.
chmod 755 "$SHOP_ROOT"

log "Stopping MariaDB."
stop_mariadb

log "Install complete."
