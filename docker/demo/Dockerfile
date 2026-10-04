# O3-Shop demo image: shop + MariaDB in one container, installed with demo
# data at build time. For demos only — not for production.
#
# Build from the repository root:
#   docker build -f docker/demo/Dockerfile -t o3-shop-demo .
# Run:
#   docker run -p 8080:80 o3-shop-demo

FROM composer:2.2 AS composer

# bookworm ships MariaDB 10.11, the version the shop's CI tests against.
FROM php:8.2-apache-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        mariadb-server \
        mariadb-client \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libzip-dev \
        libicu-dev \
        libxml2-dev \
        libbz2-dev \
        unzip \
        git \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql \
        mysqli \
        gd \
        intl \
        zip \
        bcmath \
        soap \
        bz2 \
        opcache \
        calendar \
        exif \
    && a2enmod rewrite \
    # Keep the runtime libraries the extensions link against, drop the
    # build-only packages (composer unpacks with PHP's zip extension).
    && apt-mark manual libicu72 libxml2 libzip4 libpng16-16 libjpeg62-turbo libfreetype6 libbz2-1.0 \
    && apt-get purge -y --auto-remove \
        git unzip libicu-dev libfreetype6-dev libjpeg62-turbo-dev libpng-dev libzip-dev libxml2-dev libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer /usr/bin/composer /usr/local/bin/composer

# Production PHP settings (no error output to visitors).
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && printf 'memory_limit = 256M\nexpose_php = Off\n' > "$PHP_INI_DIR/conf.d/o3-shop.ini"

# Serve the shop's source/ directory, with .htaccess (SEO URLs) enabled.
RUN sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html/source|' /etc/apache2/sites-available/000-default.conf \
    && printf '<Directory /var/www/html/source>\n    AllowOverride All\n    Require all granted\n</Directory>\n' \
        > /etc/apache2/conf-available/o3-shop.conf \
    && a2enconf o3-shop

WORKDIR /var/www/html

COPY composer.json ./
RUN COMPOSER_ALLOW_SUPERUSER=1 composer install \
        --no-dev --no-interaction --no-progress --optimize-autoloader \
    && rm -rf /root/.composer/cache

COPY docker/demo/install.sh docker/demo/entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/install.sh /usr/local/bin/entrypoint.sh \
    && /usr/local/bin/install.sh

ENV O3_SHOP_URL=http://localhost:8080 \
    O3_ADMIN_EMAIL=admin@example.com \
    O3_ADMIN_PASSWORD=admin123

EXPOSE 80
# The php:apache base image stops with SIGWINCH (Apache graceful stop). The
# entrypoint traps SIGTERM to stop Apache and then shut MariaDB down cleanly.
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]
