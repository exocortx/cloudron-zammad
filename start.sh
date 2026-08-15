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

# Start a TCP forwarder on 127.0.0.1:5432 → $DB_HOST:$DB_PORT via socat.
# This solves the Cloudron PostgreSQL pg_hba.conf / IPv6 source IP issue:
#   - Cloudron DNS returns both A and AAAA records for the postgres service.
#   - Ruby's pg gem prefers IPv6, but pg_hba.conf only authorises the IPv4
#     docker bridge addresses — or only localhost.
#   - By proxying through 127.0.0.1, Zammad connects "from localhost" which
#     PostgreSQL always accepts (trust/local auth in pg_hba.conf).
socat TCP-LISTEN:5432,reuseaddr,fork,bind=127.0.0.1 TCP:${DB_HOST}:${DB_PORT} &
SOCAT_PID=$!
trap "kill $SOCAT_PID 2>/dev/null || true" EXIT

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

# First boot: init Zammad (create DB, migrate, seed, configure FQDN)
if [ ! -f /app/data/.initialized ]; then
    echo "First boot: initialising Zammad database..."

    # Wait for postgres to be ready (via local forwarder)
    until pg_isready -q -h 127.0.0.1 -p 5432; do
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