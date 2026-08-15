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
DOMAIN="${CLOUDRON_APP_DOMAIN}"

# Configure Zammad to use Cloudron addons
export POSTGRESQL_HOST="$DB_HOST"
export POSTGRESQL_PORT="$DB_PORT"
export POSTGRESQL_USER="$DB_USER"
export POSTGRESQL_PASS="$DB_PASS"
export POSTGRESQL_DB="$DB_NAME"
export REDIS_URL="redis://${REDIS_HOST}:${REDIS_PORT}"
export MEMCACHE_SERVERS="127.0.0.1:11211"
export NGINX_PORT=8080
export NGINX_SERVER_NAME="${DOMAIN}"
export NGINX_SERVER_SCHEME="https"
export RAILS_TRUSTED_PROXIES="127.0.0.1,::1"
export ZAMMAD_FQDN="${DOMAIN}"
export ZAMMAD_HTTP_TYPE="https"
export ELASTICSEARCH_ENABLED=false

cd /opt/zammad

# First boot: create database, run migrations, seed
if [ ! -f /app/data/.initialized ]; then
    echo "First boot: initialising Zammad database..."

    # Wait for postgres
    until pg_isready -q -h "$DB_HOST" -p "$DB_PORT"; do
        echo "  waiting for postgresql..."
        sleep 2
    done

    # Create DB if needed
    bundle exec rake db:create 2>&1 || echo "DB may already exist"

    # Run migrations
    bundle exec rake db:migrate 2>&1

    # Seed
    bundle exec rake db:seed 2>&1

    # Generate FQDN config
    bundle exec rails r "Setting.set('fqdn', '${DOMAIN}')" 2>&1

    touch /app/data/.initialized
fi

# Ensure storage dir exists for persistent data
mkdir -p /app/data/storage
[ -L /opt/zammad/storage ] || rm -rf /opt/zammad/storage && ln -s /app/data/storage /opt/zammad/storage

# Run supervisord
exec /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf -n
