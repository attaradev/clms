FROM php:8.3-fpm-alpine3.20 AS base

ARG UID=1000
ARG GID=1000
ARG USER=app

ENV UID=${UID} \
    GID=${GID} \
    USER=${USER}

RUN mkdir -p /var/www/html
WORKDIR /var/www/html

# Remove unused group if present
RUN delgroup dialout || true

# Runtime user
RUN addgroup -g ${GID} -S ${USER} \
    && adduser  -S -D -G ${USER} -s /bin/sh -u ${UID} ${USER}

# Configure PHP-FPM user and logging
RUN sed -i "s/user = www-data/user = ${USER}/"  /usr/local/etc/php-fpm.d/www.conf \
    && sed -i "s/group = www-data/group = ${USER}/" /usr/local/etc/php-fpm.d/www.conf \
    && echo "php_admin_flag[log_errors] = on" >> /usr/local/etc/php-fpm.d/www.conf

# System deps for extensions
RUN apk add --no-cache \
    git curl unzip \
    libpng-dev libjpeg-turbo-dev freetype-dev \
    libzip-dev \
    postgresql-dev \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS

# PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" gd exif zip \
    && docker-php-ext-install -j"$(nproc)" pdo pdo_pgsql

# Redis extension
RUN pecl install redis \
    && docker-php-ext-enable redis

# Drop build deps
RUN apk del .build-deps

# Composer stage to install vendors
FROM base AS vendor
# Provide composer in this stage using the official image binary
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
WORKDIR /app
COPY back-end/composer.json back-end/composer.lock ./
# Now that required PHP extensions (gd, exif, zip, pdo_pgsql) are present in this stage,
# composer can resolve platform requirements without ignoring extensions.
RUN composer install --no-dev --prefer-dist --no-interaction --no-progress --optimize-autoloader --no-scripts

# Final stage
FROM base AS app
WORKDIR /var/www/html

# Copy application code
COPY back-end/ .

# Copy vendor from composer stage
COPY --from=vendor /app/vendor ./vendor

# Ensure storage/cache writable
RUN chown -R ${USER}:${USER} storage bootstrap/cache \
    && mkdir -p storage/logs storage/framework/sessions storage/framework/cache storage/framework/views \
    && chown -R ${USER}:${USER} storage

USER ${USER}

CMD ["php-fpm", "-F"]
