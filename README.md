# Zammad Helpdesk (Cloudron Package)

Open-source ticketing & customer support platform, packaged for Cloudron.

## Features

- Multi-channel support (email, web, chat, social)
- Ticket management with SLAs
- Knowledge base
- REST API
- AGPL-3.0 licensed

## Architecture

- **Base**: `zammad/zammad:7.1.2-0013` (official Zammad image)
- **Stack**: nginx + Rails (Puma) + WebSocket + Scheduler + Memcached
- **Addons**: PostgreSQL 16 (Cloudron), Redis 7 (Cloudron)
- **Persistence**: `/app/data/storage` (Zammad uploads + temp files)

## Install (Community App)

In Cloudron UI:
1. Settings → App Store → Install custom app
2. URL: `https://raw.githubusercontent.com/Arkad-Agency/cloudron-zammad/main/CloudronVersions.json`

## Build locally

```bash
docker build -t cloudron-zammad:0.1.0 .
cloudron build --image cloudron-zammad:0.1.0
```

## Versions

- **0.1.0** — initial release, Zammad 7.1.2

## License

Zammad: AGPL-3.0
Packaging: MIT
