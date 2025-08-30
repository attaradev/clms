#!/bin/sh
set -e

export COMPOSER_CACHE_DIR=/tmp/composer-cache

# Ensure writable dirs
mkdir -p storage/framework/{cache,sessions,testing,views} storage/logs bootstrap/cache
chown -R ${UID:-1000}:${GID:-1000} storage bootstrap/cache || true
chmod -R ug+rw storage bootstrap/cache || true

# Install deps if needed
if [ ! -f vendor/autoload.php ]; then
  echo "[entrypoint] Installing PHP dependencies..."
  composer install --no-dev --prefer-dist --no-interaction --no-progress
fi

# Always clear caches first so env from compose takes effect
echo "[entrypoint] Clearing Laravel caches..."
php artisan optimize:clear || true

# Wait for Postgres via raw PDO (no artisan, avoids boot cycle)
echo "[entrypoint] Waiting for database (${DB_HOST}:${DB_PORT})..."
ATTEMPTS=0
until php -d detect_unicode=0 -r '
  $h=getenv("DB_HOST") ?: "db";
  $p=getenv("DB_PORT") ?: "5432";
  $d=getenv("DB_DATABASE") ?: "postgres";
  $u=getenv("DB_USERNAME") ?: "postgres";
  $pw=getenv("DB_PASSWORD") ?: "";
  try {
    $dsn = "pgsql:host=$h;port=$p;dbname=$d";
    $pdo = new PDO($dsn, $u, $pw, [PDO::ATTR_TIMEOUT => 2]);
  } catch (Throwable $e) { exit(1); }
' ; do
  ATTEMPTS=$((ATTEMPTS+1))
  if [ "$ATTEMPTS" -ge 60 ]; then
    echo "[entrypoint] Gave up waiting for DB after $ATTEMPTS attempts."
    exit 1
  fi
  >&2 echo "[entrypoint] Database is unavailable - sleeping"
  sleep 2
done

# Generate app key if missing
if [ -z "${APP_KEY}" ] || [ "${APP_KEY}" = "base64:" ]; then
  echo "[entrypoint] Generating application key..."
  php artisan key:generate --force
fi

# Storage symlink
if [ ! -L "public/storage" ]; then
  echo "[entrypoint] Linking storage..."
  php artisan storage:link || true
fi

# Run migrations
echo "[entrypoint] Running migrations..."
php artisan migrate --force

# Optional seed
if [ "${SEED_ON_BOOT}" = "true" ] || [ "${SEED_ON_BOOT}" = "1" ]; then
  echo "[entrypoint] Seeding database..."
  php artisan db:seed --force || true
fi

echo "[entrypoint] Starting: $*"
exec "$@"
