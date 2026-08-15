# Zammad Helpdesk Cloudron Packaging
FROM zammad/zammad:7.1.2-0013

USER root

# Install memcached + supervisord for running server processes in one container
RUN apt-get update && apt-get install -y --no-install-recommends \
        memcached \
        supervisor \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Configure supervisord to run railsserver, websocket, scheduler, memcached, nginx
COPY supervisord.conf /etc/supervisor/supervisord.conf

# Cloudron start script
COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

# Persist Zammad data
VOLUME ["/opt/zammad/storage"]

# Expose HTTP port (Cloudron expects httpPort from manifest)
EXPOSE 8080

# Default Cloudron container process
CMD ["/app/code/start.sh"]
