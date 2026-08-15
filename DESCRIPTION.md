Zammad is a web-based, open-source helpdesk/customer support system written in Ruby on Rails.

With Zammad, you can manage customer requests via:

- A modern web interface
- Email integration (incoming/outgoing)
- Social media (Facebook, Twitter, Telegram)
- Chat
- Telephony integrations
- REST API

Features:
- Multi-channel: email, web form, chat, phone, social
- Ticket management with SLA tracking
- Knowledge base
- Multi-tenant capable
- Reporting and dashboards
- Extensible via API and integrations
- Fully self-hosted (no SaaS dependency)
- AGPL-3.0 licence

This Cloudron package bundles Zammad with PostgreSQL (via Cloudron addon), Redis (via Cloudron addon), and Memcached (bundled locally). Elasticsearch is disabled by default for simplicity; full-text search uses PostgreSQL FTS.
