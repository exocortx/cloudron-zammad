# Zammad Helpdesk Cloudron Packaging
# Adapted from jojojo/cloudron-zammad for upstream-proven single-container setup.
FROM ghcr.io/zammad/zammad:7.1.2-0013

USER root

# Only supervisor is added on top of the official image: it orchestrates the
# railsserver/websocket/scheduler/nginx processes exposed by the upstream
# docker-entrypoint. Memcached is intentionally NOT installed: without
# MEMCACHE_SERVERS, Zammad's own config/application.rb cleanly falls back to a
# file-based cache store, so it is not required to run correctly.
RUN apt-get update && \
    apt-get install -y --no-install-recommends supervisor && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Cloudron containers run with a read-only root filesystem at runtime; only
# /tmp, /run and /app/data are writable. Zammad's tmp/ directory (Rails cache,
# pidfiles, sockets, the autowizard payload) is baked into the image layers and
# doesn't need to survive restarts, so redirect it to /run instead.
RUN rm -rf /opt/zammad/tmp && ln -s /run/zammad-tmp /opt/zammad/tmp

# Zammad defaults to storing attachments in PostgreSQL (Setting "storage_provider"
# = "DB"), so this path is unused in normal operation. It only matters if an
# admin later switches the storage provider to "Filesystem": in that case files
# must land on Cloudron's persistent, backed-up /app/data volume rather than the
# read-only image layer, so replace the baked-in directory with a symlink here
# (it cannot be created at runtime since /opt/zammad is read-only).
RUN rm -rf /opt/zammad/storage && ln -s /app/data/storage /opt/zammad/storage

# nginx (bundled in the base image) is compiled with default temp paths under
# /var/lib/nginx, which is also read-only at runtime on Cloudron. Redirect them
# to /run/nginx/* (created and chowned in start.sh).
RUN sed -i \
      -e '/^http {/a\        client_body_temp_path /run/nginx/body;' \
      -e '/^http {/a\        proxy_temp_path /run/nginx/proxy;' \
      -e '/^http {/a\        fastcgi_temp_path /run/nginx/fastcgi;' \
      -e '/^http {/a\        scgi_temp_path /run/nginx/scgi;' \
      -e '/^http {/a\        uwsgi_temp_path /run/nginx/uwsgi;' \
      /etc/nginx/nginx.conf

# The zammad-nginx entrypoint step writes a generated resolver.conf into
# /etc/nginx/conf.d/ and a generated vhost into /etc/nginx/sites-enabled/ on
# every start. Both directories are read-only on Cloudron, so replace them with
# symlinks into /run/nginx (created and chowned in start.sh).
RUN rm -rf /etc/nginx/conf.d /etc/nginx/sites-enabled && \
    ln -s /run/nginx/conf.d /etc/nginx/conf.d && \
    ln -s /run/nginx/sites-enabled /etc/nginx/sites-enabled

COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY start.sh /app/code/start.sh

RUN chmod +x /app/code/start.sh

# Expose HTTP port (Cloudron expects httpPort from manifest)
EXPOSE 8080

# Default Cloudron container process
CMD ["/app/code/start.sh"]