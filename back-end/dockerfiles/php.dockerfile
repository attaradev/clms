FROM php:8.3-fpm-alpine3.20

ARG UID=1000
ARG GID=1000
ARG USER=app

ENV UID=${UID} \
    GID=${GID} \
    USER=${USER}

# Workdir
RUN mkdir -p /var/www/html
WORKDIR /var/www/html

# Remove unused group if present
RUN delgroup dialout || true

# Runtime user
RUN addgroup -g ${GID} -S ${USER} \
    && adduser  -S -D -G ${USER} -s /bin/sh -u ${UID} ${USER}

# Run php-fpm as ${USER}
RUN sed -i "s/user = www-data/user = ${USER}/"  /usr/local/etc/php-fpm.d/www.conf \
    && sed -i "s/group = www-data/group = ${USER}/" /usr/local/etc/php-fpm.d/www.conf \
    && echo "php_admin_flag[log_errors] = on" >> /usr/local/etc/php-fpm.d/www.conf

# System deps for extensions & Composer
# (PHPIZE_DEPS is defined in the base image)
RUN apk add --no-cache \
    git curl unzip \
    libpng-dev libjpeg-turbo-dev freetype-dev \
    libzip-dev \
    postgresql-dev \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS

# PHP extensions
# gd flags changed in PHP 8+: use --with-freetype --with-jpeg
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" gd exif zip \
    && docker-php-ext-install -j"$(nproc)" pdo pdo_pgsql

# If you ALSO need MySQL, uncomment the next line:
# RUN docker-php-ext-install -j"$(nproc)" pdo_mysql

# Redis extension (use PECL for PHP 8.3 compatibility)
RUN pecl install redis \
    && docker-php-ext-enable redis

# Drop build deps
RUN apk del .build-deps

# Composer CLI
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

USER ${USER}

# Foreground mode for Docker
CMD ["php-fpm", "-F"]
