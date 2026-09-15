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
create table if not exists public.tryton_snipe_category_map (
   id                serial primary key,
   tryton_name       text not null,
   snipe_category_id integer,
   snipe_name        text,
   created_at        timestamptz,
   updated_at        timestamptz
);

create unique index if not exists uq_tscm_tryton_name on
   public.tryton_snipe_category_map (
      tryton_name
   );

-- -----------------------------------------------------------------
-- 2. tryton_snipe_model_map
--    Matching column para upsert: tryton_model_id (UNIQUE)
-- -----------------------------------------------------------------
create table if not exists public.tryton_snipe_model_map (
   id                serial primary key,
   tryton_model_id   integer not null,
   tryton_name       text not null,
   snipe_model_id    integer,
   snipe_category_id integer,
   snipe_name        text,
   created_at        timestamptz,
   updated_at        timestamptz
);

create unique index if not exists uq_tsmm_tryton_model_id on
   public.tryton_snipe_model_map (
      tryton_model_id
   );

-- -----------------------------------------------------------------
-- 3. tryton_snipe_status_map
--    Matching column para upsert: tryton_name (UNIQUE)
-- -----------------------------------------------------------------
create table if not exists public.tryton_snipe_status_map (
   id              serial primary key,
   tryton_name     text not null,
   snipe_status_id integer,
   snipe_name      text,
   status_type     text,
   created_at      timestamptz,
   updated_at      timestamptz
);

create unique index if not exists uq_tssm_tryton_name on
   public.tryton_snipe_status_map (
      tryton_name
   );

-- -----------------------------------------------------------------
-- 4. integration_sync_log
--    Solo INSERT (no upsert). PK BIGSERIAL.
-- -----------------------------------------------------------------
create table if not exists public.integration_sync_log (
   id               bigserial primary key,
   workflow_name    text,
   execution_id     text,
   source_system    text not null,
   entity           text not null,
   entity_id        integer,
   entity_tag       text,
   operation        text not null,
   tryton_id        integer,
   snipe_id         integer,
   operation_detail text,
   request_payload  text,
   response_status  integer,
   response_body    text,
   error_message    text,
   created_at       timestamptz default now(),
   retry_count      integer default 0,
   resolved         boolean default false,
   resolved_at      timestamptz
);

create index if not exists ix_isl_execution_id on
   public.integration_sync_log (
      execution_id
   );

create index if not exists ix_isl_created_at on
   public.integration_sync_log (
      created_at
   desc );

-- -----------------------------------------------------------------
-- 5. staging_tryton_assets — orquestador v2 (batch)
--    Tabla efímera por ejecución. Matching column: tryton_asset_id (UNIQUE).
--    La usa: Reset staging, Load staging (bulk), Diff assets (batch),
--    Run summary. ON CONFLICT (tryton_asset_id) DO NOTHING.
-- -----------------------------------------------------------------
create table if not exists public.staging_tryton_assets (
   tryton_asset_id   integer not null,
   code              text,
   internal_code     text,
   name              text,
   asset_state       text,
   tryton_model_id   integer,
   tryton_model_name text,
   category_name     text
);

create unique index if not exists uq_sta_tryton_asset_id on
   public.staging_tryton_assets (
      tryton_asset_id
   );

-- -----------------------------------------------------------------
-- 6. tryton_snipe_asset_map — orquestador v2 (batch)
--    Mapa de activos. Matching column: tryton_asset_id (UNIQUE).
--    Columnas alineadas con Upsert asset map / Diff assets (batch).
-- -----------------------------------------------------------------
create table if not exists public.tryton_snipe_asset_map (
   tryton_asset_id      integer not null,
   tryton_code          text,
   tryton_internal_code text,
   tryton_name          text,
   tryton_asset_state   text,
   tryton_model_id      integer,
   snipe_asset_id       integer,
   snipe_asset_tag      text,
   snipe_model_id       integer,
   snipe_status_id      integer,
   snipe_name           text,
   created_at           timestamptz default now(),
   updated_at           timestamptz default now(),
   last_synced_at       timestamptz default now()
);

create unique index if not exists uq_tsam_tryton_asset_id on
   public.tryton_snipe_asset_map (
      tryton_asset_id
   );

create index if not exists ix_tsam_snipe_asset_id on
   public.tryton_snipe_asset_map (
      snipe_asset_id
   );

-- -----------------------------------------------------------------
-- 7. tryton_snipe_run_summary — orquestador v2 (batch)
--    Resumen por ejecución. run_id = $execution.id.
-- -----------------------------------------------------------------
create table if not exists public.tryton_snipe_run_summary (
   id                bigserial primary key,
   run_id            text not null,
   total_tryton      integer,
   to_create         integer,
   to_update         integer,
   unchanged         integer,
   missing_model     integer,
   deleted_in_tryton integer,
   api_errors        integer,
   finished_at       timestamptz default now()
);

create unique index if not exists uq_tsrs_run_id on
   public.tryton_snipe_run_summary (
      run_id
   );

-- -----------------------------------------------------------------
-- 8. staging_titular — Tryton sync titular-activo (v1)
--    Tabla efímera por ejecución. La usa: Reset staging titular
--    (DELETE), Cargar staging titular (jsonb_to_recordset), Diff
--    titular y Contar omitidos. Sin PK; se trunca al inicio.
-- -----------------------------------------------------------------
create table if not exists public.staging_titular (
   snipe_asset_tag text,
   email           text,
   first_name      text,
   last_name       text
);

-- -----------------------------------------------------------------
-- 9. snipe_titular_user_map — cache email → snipe_user_id
--    Matching column para upsert: email (PK)
-- -----------------------------------------------------------------
create table if not exists public.snipe_titular_user_map (
   email         text primary key,
   snipe_user_id integer not null,
   updated_at    timestamptz default now()
);

-- -----------------------------------------------------------------
-- 10. snipe_titular_map — titular vigente por activo
--     Matching column para upsert: snipe_asset_tag (PK)
-- -----------------------------------------------------------------
create table if not exists public.snipe_titular_map (
   snipe_asset_tag text primary key,
   email           text not null,
   snipe_user_id   integer not null,
   updated_at      timestamptz default now()
);