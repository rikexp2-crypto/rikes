-- =====================================================================
-- CRM Unificado — Identidade Cross-Channel (Site / WhatsApp / Instagram)
-- PostgreSQL 15+
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ---------------------------------------------------------------------
-- Pessoa única (independente de por qual canal ela falou primeiro)
-- ---------------------------------------------------------------------
CREATE TABLE contacts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    display_name    TEXT,
    email           CITEXT UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    merged_into     UUID REFERENCES contacts(id)  -- se este registro foi mesclado em outro
);

-- ---------------------------------------------------------------------
-- Cada identificador de canal aponta para uma pessoa (contact_id).
-- Permite N canais -> 1 pessoa (WhatsApp hoje, Instagram amanhã).
-- ---------------------------------------------------------------------
CREATE TYPE channel_type AS ENUM ('whatsapp', 'instagram', 'site', 'messenger');

CREATE TABLE contact_channels (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    contact_id      UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    channel         channel_type NOT NULL,
    -- valor normalizado do identificador nesse canal:
    -- whatsapp -> telefone E.164 (+5511999999999)
    -- instagram -> IGSID (id numérico interno da Meta) + handle (@usuario)
    -- site -> email ou id de cadastro do Graficaplus
    external_id     TEXT NOT NULL,
    handle          TEXT,               -- @usuario do Instagram, se aplicável
    verified_strong CHAR(1) NOT NULL DEFAULT 'N', -- 'Y' se identificador forte (tel/email confirmado)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (channel, external_id)
);

CREATE INDEX idx_contact_channels_contact_id ON contact_channels(contact_id);

-- ---------------------------------------------------------------------
-- Origem de campanha (Meta Ads) — atribuição de ROI
-- ---------------------------------------------------------------------
CREATE TABLE lead_sources (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    contact_id      UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    utm_source      TEXT,
    utm_campaign    TEXT,
    ctwa_clid       TEXT,              -- click-to-WhatsApp/Instagram ad id (Meta)
    ad_id           TEXT,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Funil / Kanban do atendimento
-- ---------------------------------------------------------------------
CREATE TYPE pipeline_stage AS ENUM (
    'lead_novo',
    'orcamento_enviado',
    'aguardando_arte',
    'pagamento_confirmado',
    'em_producao',
    'entregue',
    'perdido'
);

CREATE TABLE deals (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    contact_id      UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    stage           pipeline_stage NOT NULL DEFAULT 'lead_novo',
    produto         TEXT,
    tiragem         INTEGER,
    valor_estimado  NUMERIC(12,2),
    valor_final     NUMERIC(12,2),
    graficaplus_pedido_id  TEXT,        -- id do pedido/orçamento no Graficaplus
    fila            TEXT,               -- vendas | arte | producao | financeiro
    assigned_agent_id UUID,             -- atendente humano responsável (Chatwoot user id)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_deals_contact_id ON deals(contact_id);
CREATE INDEX idx_deals_stage ON deals(stage);
CREATE INDEX idx_deals_graficaplus_pedido_id ON deals(graficaplus_pedido_id);

-- ---------------------------------------------------------------------
-- Histórico de eventos do Graficaplus (auditoria + reprocessamento)
-- ---------------------------------------------------------------------
CREATE TABLE graficaplus_events (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_type      TEXT NOT NULL,      -- novo_pedido | novo_orcamento | novo_cadastro | status_alterado
    raw_payload     JSONB NOT NULL,
    contact_id      UUID REFERENCES contacts(id),
    processed       BOOLEAN NOT NULL DEFAULT FALSE,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at    TIMESTAMPTZ
);

CREATE INDEX idx_graficaplus_events_processed ON graficaplus_events(processed);

-- ---------------------------------------------------------------------
-- Log de mensagens (espelho leve do Chatwoot, para RAG/histórico da IA)
-- ---------------------------------------------------------------------
CREATE TYPE message_direction AS ENUM ('inbound', 'outbound');

CREATE TABLE messages (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    contact_id      UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    channel         channel_type NOT NULL,
    direction       message_direction NOT NULL,
    sender          TEXT NOT NULL,      -- 'ia' | 'humano:<agent_id>' | 'cliente'
    content         TEXT,
    chatwoot_conversation_id TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_messages_contact_id_created_at ON messages(contact_id, created_at DESC);

-- ---------------------------------------------------------------------
-- Função utilitária: encontra ou cria contato a partir de um identificador
-- de canal, aplicando merge automático quando há match forte.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION find_or_create_contact(
    p_channel channel_type,
    p_external_id TEXT,
    p_handle TEXT DEFAULT NULL,
    p_email CITEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    v_contact_id UUID;
BEGIN
    -- 1. já existe esse canal cadastrado?
    SELECT contact_id INTO v_contact_id
    FROM contact_channels
    WHERE channel = p_channel AND external_id = p_external_id;

    IF v_contact_id IS NOT NULL THEN
        RETURN v_contact_id;
    END IF;

    -- 2. match forte por e-mail?
    IF p_email IS NOT NULL THEN
        SELECT id INTO v_contact_id FROM contacts WHERE email = p_email;
    END IF;

    -- 3. nenhum match -> cria pessoa nova
    IF v_contact_id IS NULL THEN
        INSERT INTO contacts (email) VALUES (p_email) RETURNING id INTO v_contact_id;
    END IF;

    INSERT INTO contact_channels (contact_id, channel, external_id, handle, verified_strong)
    VALUES (v_contact_id, p_channel, p_external_id, p_handle,
            CASE WHEN p_channel = 'whatsapp' OR p_email IS NOT NULL THEN 'Y' ELSE 'N' END);

    RETURN v_contact_id;
END;
$$ LANGUAGE plpgsql;
