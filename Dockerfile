# Zammad Helpdesk Cloudron Packaging
FROM zammad/zammad:7.1.2-0013

USER root

# Install memcached + supervisord + socat for running server processes in one container
# socat is used as a localhost→postgres TCP forwarder so Zammad connects via 127.0.0.1
# (which PostgreSQL always authorises in pg_hba.conf), avoiding the IPv6/IPv4 source IP
# matching issues with the Cloudron PostgreSQL addon over the docker bridge.
RUN apt-get update && apt-get install -y --no-install-recommends \
        memcached \
        supervisor \
        curl \
        socat \
    && rm -rf /var/lib/apt/lists/*

# Configure supervisord to run railsserver, websocket, scheduler, memcached, nginx
COPY supervisord.conf /etc/supervisor/supervisord.conf

# Cloudron start script + zammad-init wrapper
COPY start.sh /app/code/start.sh
COPY zammad-init-wrapper.sh /app/code/zammad-init-wrapper.sh
RUN chmod +x /app/code/start.sh /app/code/zammad-init-wrapper.sh

# Persist Zammad data
VOLUME ["/opt/zammad/storage"]

# Expose HTTP port (Cloudron expects httpPort from manifest)
EXPOSE 8080

# Default Cloudron container process
CMD ["/app/code/start.sh"]
