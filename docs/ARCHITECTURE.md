# Arquitetura — Central Omnichannel de IA (Gráfica Plus / Artereioficial)

> Baseado no benchmark descrito (painel unificado de conversas, agente de IA
> para orçamento automático, CRM Kanban, notificações automáticas de pedido
> e rastreamento de campanhas Meta Ads) e no levantamento técnico real feito
> no painel da plataforma **Gráfica Plus** (graficaplus.com.br/admin, loja
> "Artereioficial"): a plataforma **confirmadamente não expõe Webhook nem
> API pública** para automações — apenas integrações fechadas de Pagamento
> (Asaas/Mercado Pago/Pix), Frete (Melhor Envio) e Pixels de anúncio (Google
> Analytics, Google Ads, Meta Pixel). O botão de WhatsApp do catálogo é um
> link `wa.me` simples (não é WhatsApp Cloud API), com cadastro obrigatório
> antes de abrir a conversa. **Por isso a arquitetura abaixo segue o Plano
> B**: o WhatsApp Cloud API oficial (que vamos configurar por fora) vira o
> ponto real de entrada dos leads, e a sincronização de status de pedido
> passa a ser manual (feita pelo atendente), não automática via webhook.
> Volume-alvo: **médio porte** (500–5.000 conversas/mês, 3–10 atendentes).

---

## 1. Componentes vitais do sistema (mapeamento do benchmark)

| Componente do vídeo | Função | Equivalente na nossa arquitetura |
|---|---|---|
| Painel unificado (inbox) | Todas as conversas (Whats/Insta/Site) em um só lugar, divididas por fila/setor | **Chatwoot** (inbox multicanal) |
| Agente de IA de orçamento | Responde 24/7, identifica produto, calcula preço, envia link de pagamento | **Agente de IA** (LLM + function calling) orquestrado via **n8n**, consultando uma **tabela de preços própria** (catálogo replicado no nosso banco, já que a Gráfica Plus não expõe API de leitura) |
| CRM Kanban | Funil visual: Lead Novo → Orçamento → Arte → Pagamento → Produção → Entregue | **Chatwoot Custom Attributes + Labels** na Fase 1; **CRM Kanban dedicado** (ex: Twenty CRM / Kanban próprio) na Fase 3 — **fonte da verdade única**, já que o Kanban interno da Gráfica Plus não sincroniza automaticamente |
| Notificações automáticas | Status do pedido muda no site → mensagem automática no canal do cliente | **Plano B**: atendente move o card no nosso Kanban (1 clique) → dispara automaticamente a notificação via **n8n → WhatsApp Cloud API**. Sem webhook nativo, a mudança de status não é 100% automática na origem, mas o disparo ao cliente sim |
| Rastreamento Meta Ads | Saber qual anúncio gerou o contato, medir ROI | **Meta Pixel (já conectado na Gráfica Plus) + Meta Conversions API + `ctwa_clid`** (click-to-WhatsApp) armazenado no lead |
| "Jarvis" — IA interna multi-agente | Assistente interno que ajuda no financeiro, artes, redes sociais, resumo semanal | **Camada de Agentes Internos (Fase 4)** — agentes especializados (Financeiro, Social, Design, Relatórios) orquestrados por um agente supervisor, com memória própria (RAG) |

> **Limitação assumida do Plano B**: como a Gráfica Plus não tem API,
> pedidos feitos pela loja (checkout, pagamento via Asaas/Mercado Pago)
> **não entram automaticamente no nosso CRM** — só entram os leads que
> chegam por mensagem (WhatsApp/Instagram). Para pedidos fechados 100%
> dentro do site sem nunca passar por chat, o atendente precisa checar o
> painel da Gráfica Plus periodicamente e lançar manualmente no nosso
> Kanban (ou, futuramente, perguntar ao suporte da Gráfica Plus por um
> export/CSV agendado de pedidos).

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

### 3.4 Gráfica Plus (plataforma SaaS de terceiros) — **confirmado: sem Webhook/API**

Levantamento técnico concluído direto no painel (`graficaplus.com.br/admin`
→ Integrações): a plataforma só expõe integrações fechadas de **Pagamento**
(Asaas, Mercado Pago, Pix), **Frete** (Melhor Envio) e **Pixels de anúncio**
(Google Analytics, Google Ads, Meta Pixel). Não existe seção de
Webhooks/API/Zapier. O botão de WhatsApp do catálogo é um link `wa.me`
simples (não é integração via API), com cadastro obrigatório do cliente
antes de abrir a conversa.

**Decisão de arquitetura (Plano B):** ao invés de depender de um evento que
a Gráfica Plus não emite, invertemos o ponto de entrada — o **WhatsApp
Cloud API oficial** (que vamos configurar como o número que recebe os
cliques do botão "falar no WhatsApp" do catálogo) passa a ser a **fonte
primária de leads em tempo real**:

1. Cliente clica no botão do catálogo → preenche cadastro (nome/telefone) →
   Gráfica Plus abre o WhatsApp com uma mensagem pré-preenchida (ex: "Olá,
   quero orçamento de [produto]").
2. Essa mensagem chega como **inbound message** no webhook do WhatsApp
   Cloud API (esse sim, 100% em tempo real e oficial).
3. O n8n extrai do texto da mensagem (regex + fallback via IA) o produto
   mencionado, cria/atualiza o contato no CRM unificado e abre o card no
   Kanban em "Lead Novo" — **sem depender de nenhum dado vindo da Gráfica
   Plus**.
4. Pedidos fechados **inteiramente dentro do checkout do site** (sem passar
   por chat) não entram automaticamente — ver limitação documentada na
   seção 1.
5. Mudança de status de pedido (arte aprovada, em produção, etc.) é feita
   **manualmente pelo atendente**, movendo o card no nosso Kanban — o que
   dispara automaticamente a notificação ao cliente via n8n → WhatsApp.

Estrutura interna que o card do Kanban carrega (preenchida por nós, não
recebida de webhook):

```json
{
  "event": "novo_lead_whatsapp | status_alterado_manual",
  "cliente": { "nome": "", "telefone": "", "email": null, "instagram": "" },
  "pedido": { "id": null, "produto": "", "tiragem": null, "valor": null, "status": "lead_novo" },
  "origem": { "utm_source": "meta_ads | catalogo_organico", "ctwa_clid": "" },
  "timestamp": ""
}
```

**Ação recomendada em paralelo:** perguntar ao suporte da Gráfica Plus se
existe (a) um export/CSV agendado de pedidos, ou (b) API liberada em planos
superiores ao "Plano Digital" — qualquer um dos dois eliminaria a
limitação do item 4 acima sem precisar de scraping.

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
  ├─ Status de pedido existente → consulta nosso CRM (deals.stage, atualizado manualmente pelo atendente) → responde
  ├─ Dúvida genérica (prazo, forma de pagamento, endereço) → responde via FAQ/RAG
  ├─ Reclamação / quer humano / sentimento negativo → [Transbordo]
  └─ Fora de escopo → [Transbordo]
  │
  ▼
[Fluxo de Orçamento]
  IA pergunta: produto → tiragem/quantidade → acabamento/opções
  → calcula preço via catálogo próprio (function call `calcular_orcamento`,
    consultando a tabela de preços replicada em `docs/DATABASE_SCHEMA.sql`,
    já que a Gráfica Plus não tem API de leitura de preços)
  → envia resumo + link do catálogo/checkout da Gráfica Plus
  → move card do Kanban para "Orçamento Enviado"
  → cliente confirma pagamento → atendente confirma manualmente (Asaas/Mercado
    Pago não tem webhook exposto pra nós) → move para "Pagamento Confirmado"
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
- Criar schema unificado do CRM (`docs/DATABASE_SCHEMA.sql`), incluindo a
  tabela de preços própria (já que não há API de catálogo da Gráfica Plus).
- Configurar WhatsApp Cloud API (App Meta, número, webhook) e conectar ao
  Chatwoot como inbox — **este número passa a ser o mesmo divulgado no
  botão "falar no WhatsApp" do catálogo da Gráfica Plus**.
- Endpoint `POST /webhook/whatsapp` no n8n recebendo mensagens inbound,
  extraindo produto/intenção do texto pré-preenchido vindo do catálogo, e
  criando o lead no CRM (substitui o webhook que a Gráfica Plus não tem).
- **Entregável de código desta fase**: `docker-compose.yml`, schema SQL,
  workflow n8n de ingestão via WhatsApp
  (`n8n/workflows/whatsapp-inbound-lead-capture.json`).

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
