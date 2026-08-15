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

# Elasticsearch is not packaged as a Cloudron addon. Leave it disabled; the
# user can configure an external Elasticsearch instance from Zammad's admin
# panel (Settings > Search Index) if desired. PostgreSQL FTS is used by default.
# Elasticsearch is enabled only if CLOUDRON_ELASTICSEARCH_URL is configured
# (Cloudron has no native ES addon). When unset, Zammad uses PostgreSQL FTS.
if [ -n "${CLOUDRON_ELASTICSEARCH_URL:-}" ]; then
    export ELASTICSEARCH_ENABLED=true
else
    export ELASTICSEARCH_ENABLED=false
fi

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

# Configure Elasticsearch if the env vars are set. Cloudron does not ship an
# ES addon, so we expose three manual env vars: CLOUDRON_ELASTICSEARCH_URL,
# _USER, _PASSWORD. The user customises them by editing the env block of the
# Cloudron app's location (the `env:` key in the manifest). If the env vars
# are absent, Zammad's defaults are left alone (PostgreSQL FTS is used).
if [ -n "${CLOUDRON_ELASTICSEARCH_URL:-}" ]; then
    echo "==> Configuring Elasticsearch backend via Cloudron env vars"
    runuser -p -u zammad -- env HOME=/tmp bash -c "cd /opt/zammad && bundle exec rails r \"
        Setting.set('es_url', '${CLOUDRON_ELASTICSEARCH_URL}')
        Setting.set('es_user', '${CLOUDRON_ELASTICSEARCH_USER:-elastic}')
        Setting.set('es_password', '${CLOUDRON_ELASTICSEARCH_PASSWORD:-}')
        Setting.set('es_index', 'zammad')
        Setting.set('es_ssl_verify', false)
        Setting.set('search_index', 'SearchIndex::Elasticsearch')
        puts 'Elasticsearch config: ' + Setting.get('es_url').to_s
    \""
    echo "==> Reindexing Zammad into Elasticsearch (one-time, may take a while)"
    runuser -p -u zammad -- env HOME=/tmp bash -c "cd /opt/zammad && bundle exec rails r 'SearchIndexJob.perform_later(true)'" || \
        echo 'WARNING: SearchIndexJob enqueue failed; trigger reindex manually from Zammad admin panel'
fi

# Configure the Email::Notification outbound channel to use the Cloudron SMTP
# relay instead of the default (unconfigured) sendmail binary. Two channels are
# created by db/seeds/channels.rb: one with adapter 'smtp' (inactive), one with
# adapter 'sendmail' (active). We deactivate the sendmail one, activate the
# SMTP one, and fill in the host/port/user/password from the sendmail addon
# env vars. CLOUDRON_MAIL_STARTTLS_PORT is preferred when available (TLS).
# Idempotent: re-running just overwrites the same record with the same values.
if [ -n "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]; then
    echo "==> Configuring Email::Notification outbound channel via Cloudron SMTP"
    SMTP_PORT="${CLOUDRON_MAIL_STARTTLS_PORT:-${CLOUDRON_MAIL_SMTP_PORT:-25}}"
    # enable_starttls_auto is a boolean (true/false), not a string. Cloudron
    # STARTTLS port is typically 587 (TLS); SMTP port 25 is plain.
    if [ "${SMTP_PORT}" != "25" ]; then
        STARTTLS="true"
    else
        STARTTLS="false"
    fi
    runuser -p -u zammad -- env HOME=/tmp bash -c "cd /opt/zammad && bundle exec rails r \"
        # Deactivate the sendmail channel (it's active by default but points to an unconfigured /usr/sbin/sendmail)
        Channel.where(area: 'Email::Notification', options: { outbound: { adapter: 'sendmail' } }).each { |c| c.update(active: false) }
        # Find or create the SMTP channel. db/seeds/channels.rb creates one on
        # fresh installs, but on an upgrade over an existing DB the channel may
        # not exist (especially if the user already created a custom sendmail
        # channel from the UI). Create it in that case so we never end up with
        # the broken sendmail channel as the only outbound option.
        ch = Channel.where(area: 'Email::Notification', options: { outbound: { adapter: 'smtp' } }).first
        if ch.nil?
          ch = Channel.create!(
            area: 'Email::Notification',
            type: 'email',
            options: {
              outbound: {
                adapter: 'smtp',
                options: {
                  host: '${CLOUDRON_MAIL_SMTP_SERVER}',
                  port: ${SMTP_PORT},
                  user: '${CLOUDRON_MAIL_SMTP_USERNAME}',
                  password: '${CLOUDRON_MAIL_SMTP_PASSWORD}',
                  enable_starttls_auto: ${STARTTLS},
                  ssl_verify: true,
                },
              },
              inbound: {},
            },
            active: true,
            preferences: { online_service_disable: false },
          )
          puts 'Email::Notification SMTP channel created: ' + ch.options['outbound']['options']['host'].to_s + ':' + ch.options['outbound']['options']['port'].to_s
        else
          ch.options['outbound']['options']['host']     = '${CLOUDRON_MAIL_SMTP_SERVER}'
          ch.options['outbound']['options']['port']     = ${SMTP_PORT}
          ch.options['outbound']['options']['user']     = '${CLOUDRON_MAIL_SMTP_USERNAME}'
          ch.options['outbound']['options']['password'] = '${CLOUDRON_MAIL_SMTP_PASSWORD}'
          ch.options['outbound']['options']['enable_starttls_auto'] = ${STARTTLS}
          ch.options['outbound']['options']['ssl_verify'] = true
          ch.active = true
          ch.preferences['online_service_disable'] = false
          ch.save!
          puts 'Email::Notification SMTP channel updated: ' + ch.options['outbound']['options']['host'].to_s + ':' + ch.options['outbound']['options']['port'].to_s
        end
    \""
fi

echo "==> Starting supervisord"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf