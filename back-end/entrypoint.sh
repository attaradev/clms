#!/bin/sh
set -e

# Composer cache to speed things up (matches compose volume)
export COMPOSER_CACHE_DIR=/tmp/composer-cache

# If vendor was overlaid by the bind mount and is empty, install deps
if [ ! -f vendor/autoload.php ]; then
  echo "Installing PHP dependencies..."
  composer install --no-dev --prefer-dist --no-interaction --no-progress
fi

echo "Waiting for database connection..."
until php artisan migrate:status >/dev/null 2>&1; do
  >&2 echo "Database is unavailable - sleeping"
  sleep 3
done

if [ -z "$APP_KEY" ] || [ "$APP_KEY" = "base64:" ]; then
  echo "Generating application key..."
  php artisan key:generate --force
fi

if [ ! -L "public/storage" ]; then
  echo "Linking storage..."
  php artisan storage:link || true
fi

echo "Running migrations..."
php artisan migrate --force

exec "$@"
