#!/usr/bin/env bash
set -e

# Cloudron env vars
DB_HOST="${CLOUDRON_POSTGRESQL_HOST}"
DB_PORT="${CLOUDRON_POSTGRESQL_PORT}"
DB_USER="${CLOUDRON_POSTGRESQL_USERNAME}"
DB_PASS="${CLOUDRON_POSTGRESQL_PASSWORD}"
DB_NAME="${CLOUDRON_POSTGRESQL_DATABASE}"
REDIS_HOST="${CLOUDRON_REDIS_HOST}"
REDIS_PORT="${CLOUDRON_REDIS_PORT}"
REDIS_PASSWORD="${CLOUDRON_REDIS_PASSWORD}"
DOMAIN="${CLOUDRON_APP_DOMAIN}"

# PG proxy target — socat runs under supervisord and forwards localhost:5432 → this.
# The pg gem's source IP (the docker bridge gateway) is rejected by Cloudron's
# pg_hba.conf, but connections from 127.0.0.1 are always accepted (trust on localhost).
export PG_PROXY_TARGET="${DB_HOST}:${DB_PORT}"

# Configure Zammad to use Cloudron addons via the local forwarder
export POSTGRESQL_HOST="127.0.0.1"
export POSTGRESQL_PORT="5432"
export POSTGRESQL_USER="$DB_USER"
export POSTGRESQL_PASS="$DB_PASS"
export POSTGRESQL_DB="$DB_NAME"
# SSL is not required for Cloudron PostgreSQL addon — pg_hba.conf allows plain IPv4
# from the docker bridge. Disable SSL explicitly to avoid TLS handshake failures.
export PGSSLMODE="disable"
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
mkdir -p /app/data/storage /app/data/tmp /app/data/log

if [ ! -e /opt/zammad/storage ]; then
    ln -s /app/data/storage /opt/zammad/storage 2>/dev/null || true
fi

cd /opt/zammad

# Run supervisord as PID 1 (required for proper signal handling in containers).
# Supervisord manages: socat pg-proxy, memcached, zammad services.
# The zammad-init program runs once on first boot to create DB / migrate / seed.
exec /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf -n