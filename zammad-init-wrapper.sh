#!/usr/bin/env bash
# Zammad first-boot wrapper. Runs under supervisord once on container start.
# Waits for PostgreSQL (via socat proxy on 127.0.0.1:5432) and Redis,
# then runs zammad-init (DB create / migrate / seed), sets FQDN,
# and marks the init flag so subsequent restarts skip this step.

set -e

DOMAIN="${CLOUDRON_APP_DOMAIN:-}"
INIT_FLAG="/app/data/.initialized"

if [ -f "$INIT_FLAG" ]; then
    echo "zammad-init: already initialised (flag exists), skipping."
    exit 0
fi

# Wait for postgres via local proxy
echo "zammad-init: waiting for PostgreSQL (127.0.0.1:5432)..."
until pg_isready -q -h 127.0.0.1 -p 5432; do
    sleep 2
done

# Wait for redis
echo "zammad-init: waiting for Redis..."
until (echo > /dev/tcp/"${CLOUDRON_REDIS_HOST}"/"${CLOUDRON_REDIS_PORT}") 2>/dev/null; do
    sleep 2
done
echo "zammad-init: redis is reachable"

cd /opt/zammad

# Run zammad-init
/opt/zammad/bin/docker-entrypoint zammad-init

# Set FQDN
if [ -n "$DOMAIN" ]; then
    bundle exec rails r "Setting.set('fqdn', '${DOMAIN}')" 2>&1 || true
fi

touch "$INIT_FLAG"
echo "zammad-init: done."