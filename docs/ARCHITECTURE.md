# Arquitetura — Central Omnichannel de IA (Graficaplus)

> Baseado no benchmark descrito (painel unificado de conversas, agente de IA
> para orçamento automático, CRM Kanban, notificações automáticas de pedido
> e rastreamento de campanhas Meta Ads) e nas respostas de escopo:
> Graficaplus é uma **plataforma SaaS de terceiros** (a confirmar API/webhooks
> nativos), WhatsApp via **Cloud API oficial (Meta)**, volume **médio porte**
> (500–5.000 conversas/mês, 3–10 atendentes).

---

## 1. Componentes vitais do sistema (mapeamento do benchmark)

| Componente do vídeo | Função | Equivalente na nossa arquitetura |
|---|---|---|
| Painel unificado (inbox) | Todas as conversas (Whats/Insta/Site) em um só lugar, divididas por fila/setor | **Chatwoot** (inbox multicanal) |
| Agente de IA de orçamento | Responde 24/7, identifica produto, calcula preço, envia link de pagamento | **Agente de IA** (LLM + function calling) orquestrado via **n8n**, consultando catálogo/preços do Graficaplus |
| CRM Kanban | Funil visual: Lead Novo → Orçamento → Arte → Pagamento → Produção → Entregue | **Chatwoot Custom Attributes + Labels** na Fase 1; **CRM Kanban dedicado** (ex: Twenty CRM / Kanban próprio) na Fase 3 |
| Notificações automáticas | Status do pedido muda no site → mensagem automática no canal do cliente | **Webhook Graficaplus → n8n → WhatsApp/Instagram API** |
| Rastreamento Meta Ads | Saber qual anúncio gerou o contato, medir ROI | **Meta Conversions API + `ctwa_clid`** (click-to-WhatsApp/Instagram ads) armazenado no lead |
| "Jarvis" — IA interna multi-agente | Assistente interno que ajuda no financeiro, artes, redes sociais, resumo semanal | **Camada de Agentes Internos (Fase 4)** — agentes especializados (Financeiro, Social, Design, Relatórios) orquestrados por um agente supervisor, com memória própria (RAG) |

---

## 2. Tech Stack — justificativa

| Camada | Ferramenta | Por quê |
|---|---|---|
| Orquestração/Automação | **n8n** (self-hosted) | Open-source, sem custo por execução (diferente do Make/Zapier em alto volume), suporta lógica complexa (branches, loops, código JS/Python), webhooks nativos, fácil versionar como JSON no Git |
| Hub de mensagens / Inbox / Kanban básico | **Chatwoot** (self-hosted) | Já resolve ~70% do "painel do vídeo" pronto: inbox multicanal, atribuição por fila/setor, múltiplos atendentes, labels, relatórios, Macros (respostas rápidas), e tem **Agent Bots via API** para plugar a IA |
| WhatsApp | **WhatsApp Cloud API** (oficial, Meta) | Você escolheu a via oficial — zero risco de banimento de número, suporta templates aprovados (notificações proativas de status de pedido), webhooks nativos |
| Instagram Direct / Comentários / Stories | **Meta Graph API (Instagram Messaging API)** | Integração nativa ao Chatwoot; cobre DM, replies a Stories e comentários via webhook de `mentions`/`comments` |
| Banco de dados | **PostgreSQL** | Usado nativamente por Chatwoot e n8n; ótimo para modelar CRM relacional + JSONB para payloads flexíveis dos webhooks do Graficaplus |
| Fila/Cache | **Redis** | Já exigido pelo Chatwoot; reutilizamos para rate-limiting e debouncing de mensagens (evitar a IA responder 5x se o cliente manda 5 mensagens seguidas) |
| LLM do Agente de IA | **Claude (Anthropic API)** via function calling | Function calling estruturado para "consultar catálogo", "calcular orçamento", "criar link de pagamento"; baixa taxa de alucinação em preços é crítico aqui |
| Geração/edição de imagem (Jarvis - Fase 4) | Modelo de imagem via API dedicada | Para apoio em criação de artes/social media |
| Hospedagem | VPS (ex: Hetzner/DigitalOcean, 4-8 vCPU / 8-16GB RAM) + Docker Compose | Suficiente para médio porte (500-5.000 conversas/mês); migra para Kubernetes só se escalar para "grande porte" |

**Por que não Make/Typebot como peça central?** Make cobra por operação
(caro em alto volume de webhooks de status de pedido); Typebot é ótimo para
formulários conversacionais simples, mas não tem inbox multiagente com fila
— por isso ele entra como **peça opcional** (ex: um typebot de pré-qualificação
embutido no site), não como substituto do Chatwoot.

---

## 3. Mapa de APIs e Webhooks

### 3.1 WhatsApp Cloud API (Meta)
- **Webhook de entrada**: `POST /webhook/whatsapp` — eventos `messages`,
  `message_status` (enviado/entregue/lido), configurado no App do Meta
  Developer Portal, verificado via `hub.verify_token`.
- **Envio**: `POST https://graph.facebook.com/v20.0/{phone-number-id}/messages`
  — mensagens de texto, templates (para notificação proativa fora da janela
  de 24h), botões interativos.
- **Requisito**: Business verificado na Meta + número dedicado (pode portar
  número existente).

### 3.2 Instagram Messaging API (Meta Graph API)
- **Webhook**: mesmo App do Meta, campos `messages`, `messaging_postbacks`,
  `comments`, `mentions` (para reações a Stories/comentários).
- **Envio**: `POST https://graph.facebook.com/v20.0/{ig-user-id}/messages`.
- **Limitação importante**: Instagram só permite responder dentro da janela
  de 24h (sem templates fora da janela, diferente do WhatsApp) — o fluxo
  precisa prever isso (ex: pedir para o cliente migrar para WhatsApp se
  passar da janela).

### 3.3 Meta Lead Ads / Conversions API
- **Webhook**: `leadgen` do Meta (Lead Ads) → captura automática de leads de
  formulários de anúncio.
- **Conversions API**: enviamos eventos de volta pro Meta (`Lead`,
  `Purchase`) para otimizar campanhas com dados reais do funil (não só
  cliques).
- **`ctwa_clid`**: parâmetro que vem automaticamente quando o cliente clica
  em anúncio "Enviar mensagem" → guardamos esse ID no primeiro contato do
  lead para atribuir a conversa à campanha de origem.

### 3.4 Graficaplus (plataforma SaaS de terceiros) — a validar
Como é uma plataforma de terceiros, o passo 1 real do projeto é o
levantamento técnico:
1. Verificar se o painel admin do Graficaplus expõe **Webhooks configuráveis**
   (novo pedido, orçamento, cadastro, mudança de status) — a maioria das
   plataformas de gráfica white-label (ex: Klingo, GraphPrime, Print2Web)
   oferece isso em "Integrações".
2. Se **não** houver webhook nativo, alternativas (em ordem de preferência):
   - **API REST de polling**: n8n consulta a cada N minutos endpoints de
     `novos pedidos`/`novos leads` (se a plataforma expuser API de leitura).
   - **Zapier/Make nativo do Graficaplus** → repassar para um webhook do n8n.
   - **Scraping autorizado do painel** (último recurso, frágil).
3. Payload esperado do webhook (a normalizar independente da origem):

```json
{
  "event": "novo_pedido | novo_orcamento | novo_cadastro | status_alterado",
  "cliente": { "nome": "", "telefone": "", "email": "", "instagram": "" },
  "pedido": { "id": "", "produto": "", "tiragem": 0, "valor": 0, "status": "" },
  "origem": { "utm_source": "", "ctwa_clid": "" },
  "timestamp": ""
}
```

Esse payload cai no endpoint `POST /webhook/graficaplus` do n8n, que
normaliza e distribui: cria/atualiza lead no CRM, dispara notificação no
canal preferido do cliente, atualiza o card no Kanban.

---

## 4. Fluxo de Atendimento Omnichannel

### 4.1 Árvore de decisão (visão geral, todos os canais)

```
Mensagem recebida (Whats/Insta/Site)
  │
  ▼
[1] Identifica cliente por telefone/IG handle/e-mail → busca no CRM unificado
  │
  ├─ Cliente novo → cria registro + tag "Lead Novo"
  └─ Cliente existente → carrega histórico completo (cross-channel)
  │
  ▼
[2] Está em atendimento humano ativo (últimas 2h)?
  ├─ SIM → só notifica atendente (IA não responde, evita conflito)
  └─ NÃO → segue para IA
  │
  ▼
[3] Agente de IA classifica intenção:
  ├─ Orçamento/produto → [Fluxo de Orçamento]
  ├─ Status de pedido existente → consulta Graficaplus API → responde
  ├─ Dúvida genérica (prazo, forma de pagamento, endereço) → responde via FAQ/RAG
  ├─ Reclamação / quer humano / sentimento negativo → [Transbordo]
  └─ Fora de escopo → [Transbordo]
  │
  ▼
[Fluxo de Orçamento]
  IA pergunta: produto → tiragem/quantidade → acabamento/opções
  → calcula preço via catálogo (function call `calcular_orcamento`)
  → envia resumo + link de checkout do Graficaplus
  → move card do Kanban para "Orçamento Enviado"
  → se cliente confirma → aguarda webhook de pagamento → move para "Pagamento Confirmado"
  │
  ▼
[Transbordo humano]
  → atribui à fila certa (Vendas/Arte/Produção/Financeiro) no Chatwoot
  → IA envia mensagem de handoff ("Já te encaminhei para nossa equipe, um
     momento!") e para de responder até atendente fechar a conversa
```

### 4.2 System Prompt do Agente de IA — ver [`AI_SYSTEM_PROMPTS.md`](AI_SYSTEM_PROMPTS.md)

Prompts separados por canal porque as regras de janela de tempo, tom e
formatação (botões, listas) diferem entre WhatsApp e Instagram.

---

## 5. Unificação de Leads (CRM cross-channel)

### Problema
Um cliente pode falar hoje pelo Instagram (`@joao.silva`) e amanhã pelo
WhatsApp (`+55 11 9xxxx-xxxx`) — sem identificador comum nativo entre os
canais.

### Estratégia de identidade única
1. **Chave primária de pessoa**: `contact_id` (UUID interno), nunca o
   telefone ou handle diretamente.
2. **Tabela de `contact_channels`**: cada canal (telefone WhatsApp, IG
   handle/PSID, e-mail do site) é um registro `N:1` apontando para o mesmo
   `contact_id`.
3. **Regras de merge automático** (rodadas pelo n8n a cada novo contato):
   - Mesmo **telefone** normalizado (E.164) → merge automático.
   - Mesmo **e-mail** → merge automático.
   - IG handle informado manualmente pelo cliente no chat ("meu insta é
     @fulano") ou capturado quando ele clica em anúncio Click-to-WhatsApp
     vindo do Instagram (o Graph API já entrega o `IGSID` linkado) → merge
     automático quando há correlação verificável.
   - Quando **não há** identificador comum forte (ex: cliente novo no
     Instagram, sem telefone ainda) → cria contato provisório e a IA
     **pergunta ativamente**: "Para eu já adiantar seu orçamento, qual é o
     seu WhatsApp?" — captura o telefone o quanto antes, é o elo mais forte.
4. **Fallback de merge manual**: atendente vê no Chatwoot um alerta
   "Possível duplicata" (nome + e-mail parecido) e confirma o merge com 1
   clique.

Ver schema completo em [`DATABASE_SCHEMA.sql`](DATABASE_SCHEMA.sql).

---

## 6. Plano de Execução por Fases

### Fase 1 — Fundação (infra + ingestão) — **em andamento neste repositório**
- Subir stack self-hosted (`infra/docker-compose.yml`): Postgres, Redis,
  n8n, Chatwoot.
- Criar schema unificado do CRM (`docs/DATABASE_SCHEMA.sql`).
- Configurar WhatsApp Cloud API (App Meta, número, webhook) e conectar ao
  Chatwoot como inbox.
- Endpoint `POST /webhook/graficaplus` no n8n recebendo `novo_pedido` /
  `novo_orcamento` / `novo_cadastro` (mesmo que via polling, se a plataforma
  não tiver webhook nativo).
- **Entregável de código desta fase**: `docker-compose.yml`, schema SQL,
  workflow n8n de ingestão (`n8n/workflows/graficaplus-webhook-ingest.json`).

### Fase 2 — Agente de IA (WhatsApp primeiro)
- Conectar Chatwoot Agent Bot ao Claude via n8n (webhook de mensagem
  recebida → n8n → Claude com function calling → resposta volta pro
  Chatwoot).
- Functions: `buscar_cliente`, `calcular_orcamento`, `consultar_status_pedido`,
  `transbordar_humano`.
- Regras de transbordo e detecção de sentimento negativo.

### Fase 3 — Instagram + CRM Kanban visual
- Conectar Instagram Messaging API ao mesmo pipeline.
- Construir/config visual de Kanban (labels do Chatwoot ou CRM dedicado)
  com automações de movimentação de card via webhook de status do
  Graficaplus.
- Notificações automáticas de status de pedido (templates WhatsApp
  aprovados).

### Fase 4 — Meta Ads + Jarvis (agentes internos)
- Rastreamento de campanha (`ctwa_clid` + Conversions API) e dashboard de
  ROI por anúncio.
- Agentes internos especializados (Financeiro, Social, Design, Relatório
  Semanal) com memória própria, orquestrados por um agente supervisor —
  acionáveis via um canal interno (ex: WhatsApp/Slack da equipe).

### Fase 5 — Escala e refinamento
- Métricas de qualidade da IA (taxa de resolução sem humano, NPS pós-
  atendimento), ajuste fino dos prompts, e — se o volume ultrapassar
  "médio porte" — migração de infra para maior redundância.

---

## Próximos passos imediatos
1. Confirmar **qual plataforma** é o Graficaplus especificamente (nome do
   sistema/fornecedor) para validar se há webhooks nativos ou se
   precisaremos de polling.
2. Criar o App no **Meta for Developers** (Business Manager) e iniciar o
   processo de verificação de negócio (leva alguns dias) — é o item de
   maior lead time, deve começar em paralelo à Fase 1.
3. Levantar o catálogo de produtos/preços do Graficaplus (fonte de verdade
   para a function `calcular_orcamento` da IA).
