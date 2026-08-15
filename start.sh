#!/usr/bin/env bash
set -e

# Cloudron env vars
# Resolve PostgreSQL/Redis hostnames to IPv4 — Cloudron DNS may return IPv6 first,
# but the addon services only accept IPv4 (pg_hba.conf / Redis listen on IPv4 only).
DB_HOST=$(getent ahostsv4 "${CLOUDRON_POSTGRESQL_HOST}" | awk 'NR==1{print $1}')
DB_PORT="${CLOUDRON_POSTGRESQL_PORT}"
DB_USER="${CLOUDRON_POSTGRESQL_USERNAME}"
DB_PASS="${CLOUDRON_POSTGRESQL_PASSWORD}"
DB_NAME="${CLOUDRON_POSTGRESQL_DATABASE}"
REDIS_HOST=$(getent ahostsv4 "${CLOUDRON_REDIS_HOST}" | awk 'NR==1{print $1}')
REDIS_PORT="${CLOUDRON_REDIS_PORT}"
REDIS_PASSWORD="${CLOUDRON_REDIS_PASSWORD}"
DOMAIN="${CLOUDRON_APP_DOMAIN}"

# Configure Zammad to use Cloudron addons
export POSTGRESQL_HOST="$DB_HOST"
export POSTGRESQL_PORT="$DB_PORT"
export POSTGRESQL_USER="$DB_USER"
export POSTGRESQL_PASS="$DB_PASS"
export POSTGRESQL_DB="$DB_NAME"
# Redis with password (Cloudron Redis addon requires auth)
export REDIS_URL="redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}"
export MEMCACHE_SERVERS="127.0.0.1:11211"
export NGINX_PORT=8080
export NGINX_SERVER_NAME="${DOMAIN}"
export NGINX_SERVER_SCHEME="https"
export RAILS_TRUSTED_PROXIES="127.0.0.1,::1"
export ZAMMAD_FQDN="${DOMAIN}"
export ZAMMAD_HTTP_TYPE="https"
export ZAMMAD_RAILSSERVER_HOST=127.0.0.1
export ZAMMAD_RAILSSERVER_PORT=3000
export ZAMMAD_WEBSOCKET_HOST=127.0.0.1
export ZAMMAD_WEBSOCKET_PORT=6042
export ELASTICSEARCH_ENABLED=false

# Persistent storage — bind mount instead of symlink (filesystem is read-only)
# Cloudron mounts /app/data, Zammad stores data in /opt/zammad/storage
# We'll bind-mount via supervisord or use a writable directory in /app/data
mkdir -p /app/data/storage /app/data/tmp /app/data/log

# Try to symlink storage (works if /opt/zammad/storage is writable or doesn't exist)
# If it fails, Zammad will use default location and we lose data on restart
# Better: bind mount the data dir entirely via supervisord
if [ ! -e /opt/zammad/storage ]; then
    ln -s /app/data/storage /opt/zammad/storage 2>/dev/null || true
fi

cd /opt/zammad

# First boot: init Zammad (create DB, migrate, seed, configure FQDN)
if [ ! -f /app/data/.initialized ]; then
    echo "First boot: initialising Zammad database..."

    # Wait for postgres to be ready
    until pg_isready -q -h "$DB_HOST" -p "$DB_PORT"; do
        echo "  waiting for postgresql..."
        sleep 2
    done

    # Wait for redis (TCP connectivity check; auth handled by REDIS_URL env var)
    echo "  waiting for redis..."
    until (echo > /dev/tcp/"$REDIS_HOST"/"$REDIS_PORT") 2>/dev/null; do
        sleep 2
    done
    echo "  redis is reachable"

    # Run zammad-init (handles DB creation, migrations, seeds)
    /opt/zammad/bin/docker-entrypoint zammad-init

    # Set FQDN
    bundle exec rails r "Setting.set('fqdn', '${DOMAIN}')" 2>&1 || true

    touch /app/data/.initialized
fi

# Run supervisord (memcached + zammad services)
exec /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf -n