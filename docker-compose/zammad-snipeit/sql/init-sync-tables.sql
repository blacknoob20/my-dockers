-- =====================================================================
-- init-sync-tables.sql — Día 0: tablas de integración Tryton → Snipe-IT
--
-- Ejecutar contra la BD n8n en docker-postgres-1:
--   docker exec -i -e PGPASSWORD=n8n_password_123 docker-postgres-1 \
--     psql -U n8n_user -d n8n -f - < sql/init-sync-tables.sql
--
-- Idempotente: seguro de ejecutar múltiples veces.
-- =====================================================================

-- -----------------------------------------------------------------
-- 1. tryton_snipe_category_map
--    Matching column para upsert: tryton_name (UNIQUE)
-- -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tryton_snipe_category_map (
    id                SERIAL PRIMARY KEY,
    tryton_name       TEXT NOT NULL,
    snipe_category_id INTEGER,
    snipe_name        TEXT,
    created_at        TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_tscm_tryton_name
    ON public.tryton_snipe_category_map (tryton_name);

-- -----------------------------------------------------------------
-- 2. tryton_snipe_model_map
--    Matching column para upsert: tryton_model_id (UNIQUE)
-- -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tryton_snipe_model_map (
    id                SERIAL PRIMARY KEY,
    tryton_model_id   INTEGER NOT NULL,
    tryton_name       TEXT NOT NULL,
    snipe_model_id    INTEGER,
    snipe_category_id INTEGER,
    snipe_name        TEXT,
    created_at        TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_tsmm_tryton_model_id
    ON public.tryton_snipe_model_map (tryton_model_id);

-- -----------------------------------------------------------------
-- 3. tryton_snipe_status_map
--    Matching column para upsert: tryton_name (UNIQUE)
-- -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tryton_snipe_status_map (
    id                SERIAL PRIMARY KEY,
    tryton_name       TEXT NOT NULL,
    snipe_status_id   INTEGER,
    snipe_name        TEXT,
    status_type       TEXT,
    created_at        TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_tssm_tryton_name
    ON public.tryton_snipe_status_map (tryton_name);

-- -----------------------------------------------------------------
-- 4. integration_sync_log
--    Solo INSERT (no upsert). PK BIGSERIAL.
-- -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.integration_sync_log (
    id                BIGSERIAL PRIMARY KEY,
    workflow_name     TEXT,
    execution_id      TEXT,
    source_system     TEXT NOT NULL,
    entity            TEXT NOT NULL,
    entity_id         INTEGER,
    entity_tag        TEXT,
    operation         TEXT NOT NULL,
    tryton_id         INTEGER,
    snipe_id          INTEGER,
    operation_detail  TEXT,
    request_payload   TEXT,
    response_status   INTEGER,
    response_body     TEXT,
    error_message     TEXT,
    created_at        TIMESTAMPTZ DEFAULT now(),
    retry_count       INTEGER DEFAULT 0,
    resolved          BOOLEAN DEFAULT false,
    resolved_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS ix_isl_execution_id
    ON public.integration_sync_log (execution_id);

CREATE INDEX IF NOT EXISTS ix_isl_created_at
    ON public.integration_sync_log (created_at DESC);
