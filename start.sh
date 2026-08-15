#!/bin/bash
#
# Cloudron entrypoint for Zammad. Runs as root. Maps Cloudron addon environment
# variables to the ones expected by the official Zammad docker-entrypoint,
# prepares the few writable runtime paths needed under Cloudron's read-only
# filesystem, runs the (idempotent) zammad-init step synchronously, then hands
# off to supervisord which runs the long-running processes as the non-root
# "zammad" user (uid/gid 1000, baked into the upstream image).
#
# Adapted from jojojo/cloudron-zammad (https://github.com/jojojo/cloudron-zammad)

set -eu

echo "==> Preparing writable runtime directories"
mkdir -p /run/zammad-tmp /run/nginx/body /run/nginx/proxy /run/nginx/fastcgi /run/nginx/scgi /run/nginx/uwsgi /run/nginx/conf.d /run/nginx/sites-enabled
chown -R zammad:zammad /run/zammad-tmp /run/nginx

mkdir -p /app/data/storage
chown -R zammad:zammad /app/data

echo "==> Mapping Cloudron environment variables to Zammad"
export POSTGRESQL_HOST="${CLOUDRON_POSTGRESQL_HOST}"
export POSTGRESQL_PORT="${CLOUDRON_POSTGRESQL_PORT}"
export POSTGRESQL_DB="${CLOUDRON_POSTGRESQL_DATABASE}"
export POSTGRESQL_USER="${CLOUDRON_POSTGRESQL_USERNAME}"
export POSTGRESQL_PASS="${CLOUDRON_POSTGRESQL_PASSWORD}"
# The Cloudron PostgreSQL addon already pre-creates the app's database and
# restricts pg_hba.conf to it (no access to the "postgres" maintenance
# database). "rake db:create" would try to connect to that "postgres" admin
# database and fail with "no pg_hba.conf entry ... database postgres", so we
# must skip it and go straight to db:migrate/db:seed.
export POSTGRESQL_DB_CREATE=false

export REDIS_URL="${CLOUDRON_REDIS_URL}"

# Elasticsearch is not packaged (yet). Zammad works without it.
export ELASTICSEARCH_ENABLED=false

# Avoid writing to the (read-only) log/ directory; ship logs to stdout instead.
export RAILS_LOG_TO_STDOUT=true

# Trust Cloudron's reverse proxy so X-Forwarded-* headers are honored.
export RAILS_TRUSTED_PROXIES="127.0.0.1,::1${CLOUDRON_PROXY_IP:+,${CLOUDRON_PROXY_IP}}"

export ZAMMAD_FQDN="${CLOUDRON_APP_DOMAIN}"
export ZAMMAD_HTTP_TYPE="https"

# All Zammad processes run inside this single container (not as separate
# docker-compose services), so nginx must reach railsserver/websocket on
# localhost rather than via their upstream service names.
export ZAMMAD_RAILSSERVER_HOST=127.0.0.1
export ZAMMAD_WEBSOCKET_HOST=127.0.0.1

echo "==> Running zammad-init (migrations / seed)"
runuser -p -u zammad -- env HOME=/tmp /opt/zammad/bin/docker-entrypoint zammad-init

# ZAMMAD_FQDN / ZAMMAD_HTTP_TYPE are only applied by Zammad's own db/seeds.rb on
# the very first install. Re-apply them on every start so a Cloudron domain
# change is picked up.
echo "==> Applying FQDN / http_type settings"
runuser -p -u zammad -- env HOME=/tmp bash -c "cd /opt/zammad && bundle exec rails r \"Setting.set('fqdn', '${ZAMMAD_FQDN}'); Setting.set('http_type', '${ZAMMAD_HTTP_TYPE}')\""

echo "==> Starting supervisord"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf