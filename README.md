# Rikes — Central de Automação Omnichannel (Gráfica Plus / Artereioficial)

Sistema de atendimento e automação com IA que unifica **WhatsApp**,
**Instagram Direct**, **Meta Ads** e o catálogo da **Gráfica Plus**
(plataforma sem Webhook/API própria — ver Plano B na arquitetura) em um
único hub de conversas, com CRM em Kanban, agente de IA para orçamentos
automáticos e notificações de status de pedido.

## Documentação

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — Arquitetura completa: stack,
  APIs/webhooks, fluxo de decisão do agente de IA, unificação de leads
  (CRM cross-channel) e plano de execução por fases.
- [`docs/DATABASE_SCHEMA.sql`](docs/DATABASE_SCHEMA.sql) — Schema Postgres
  do CRM unificado (identidade cross-channel, conversas, pedidos, filas).
- [`docs/AI_SYSTEM_PROMPTS.md`](docs/AI_SYSTEM_PROMPTS.md) — System prompts
  do agente de IA por canal (WhatsApp, Instagram, Site).
- [`infra/docker-compose.yml`](infra/docker-compose.yml) — Stack self-hosted
  da Fase 1 (n8n, Chatwoot, Postgres, Redis).
- [`n8n/workflows/`](n8n/workflows/) — Fluxos de automação (JSON importável
  no n8n).

## Status

**Fase 1** em andamento: captura de leads via WhatsApp Cloud API (Plano B —
a Gráfica Plus não tem Webhook/API) + estrutura de banco unificado.
