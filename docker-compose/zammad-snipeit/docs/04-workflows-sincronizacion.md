# 4. Workflows de Sincronizacion Tryton -> Snipe-IT

Este documento describe los workflows de negocio que sincronizan datos de Tryton hacia Snipe-IT. Complementa `03-integracion-n8n-tryton.md` (autenticacion) y el spec `.ai/specs/tryton-activos.md`.

## Indice

- [4.1 Workflow principal: Tryton sync snipe-IT assets orchestrator v2](#41-workflow-principal-tryton-sync-snipe-it-assets-orchestrator-v2)
- [4.2 Tryton sync categories](#42-tryton-sync-categories)
- [4.3 Tryton sync snipe-IT models](#43-tryton-sync-snipe-it-models)
- [4.4 Tryton sync snipe-IT status](#44-tryton-sync-snipe-it-status)
- [4.5 Tryton sync snipe-IT assets ingest (batch)](#45-tryton-sync-snipe-it-assets-ingest-batch)
- [4.6 Tryton sync titular-activo (v1)](#46-tryton-sync-titular-activo-v1)
- [4.7 Tablas de mapeo](#47-tablas-de-mapeo)
- [4.8 Limitaciones y errores conocidos](#48-limitaciones-y-errores-conocidos)

---

## 4.1 Workflow principal: Tryton sync snipe-IT assets orchestrator

**Archivo:** `flows/flujos-dev/Tryton sync snipe-IT assets orchestrator.json` (antes `... orchestrator v2 (batch).json`, dado de baja: duplicado con el mismo workflow-ID)

**ID:** `BFfvossXQY8Ck5zh` — activo

### Ejecucion

- Trigger: **manual** (`When clicking 'Execute workflow'`). No es un webhook.
- **Fase 1 — catálogos:** login → categorías y estados en paralelo (`Execute Tryton sync snipe-IT categories` / `status`) → `Wait categories & statuses` → modelos (`Execute Tryton sync snipe-IT models`, lote completo en 1 item, modo once — sin `Split Out models`).
- **Fase 2 — batch PG (activos):** `Execute Tryton sync snipeIT models` → `Prepare staging payload` (`Code`, `const assets = $('Flatten assets').first().json.result` → `payload: JSON.stringify(rows), total`) → `Execute ingest (batch)` (sub-workflow `Tryton sync snipe-IT assets ingest (batch)` vía `Execute Workflow`, inputs `{payload, total}`, `waitForSubWorkflow: true`) → `Sync titular activo` (sub-workflow `Tryton sync titular-activo (v1)`). Detalle del ingest: ver §4.5.

> **Estado:** experimental. Los workflows viejos en `flows/` fueron reemplazados por sub-workflows en `flows/flujos-dev/`.

> **Fix 2026-08-28 (PG-DDL):** los 6 nodos Postgres de la fase 2 (ahora en el sub-workflow `assets ingest`, §4.5) apuntaban a `staging_tryton_assets`, `tryton_snipe_asset_map` y `sync_run_summary` que no existían en la BD `n8n`. Se añadió DDL §5-7 a `sql/init-sync-tables.sql` y se aplicó (ver §4.6).

> **Fix 2026-08-28 (Wait models):** Merge `Wait models` (`mode: chooseBranch`, input 1→output 1 no conectado → fase 2 nunca disparaba) eliminado; `Execute Tryton sync snipeIT models` conecta directo a `Prepare staging payload`; `Prepare staging payload` migrado de `$('Wait models')` a `$('Flatten assets')`. `Wait categories & statuses` queda pendiente (mismo patrón `chooseBranch`, sólo passthrough).

> **Fix 2026-08-28 (batch models):** `Split Out models` eliminado del orquestador; `Execute Tryton sync snipeIT models` en modo once (`waitForSubWorkflow: true`) pasa el lote en 1 item. El sub resuelve mapas en 1 query (`jsonb_to_recordset`), filtra no-ops y hace upsert bulk (`ON CONFLICT (tryton_model_id)`); self-heal/log quedan por-item. Detalle en §4.3.

> **Fix 2026-08-31 (freeze UI):** `Search assets` (`model.asset.search_read`) `0, null, null` (~9.5k filas → 7-10 MB `execution_entity.jsonSizeBytes`, runs 288/1053/1054) congelaba navegador. Fix inicial `0,100,null` + `settings.saveDataSuccessExecution: none / saveDataErrorExecution: all / saveExecutionProgress: false / executionTimeout: 3600` en 6 workflows + `UPDATE workflow_entity` y limpieza de executions pesadas; con `100` solo se veían 23/558 modelos.
> **Fix 2026-08-31 (full fetch + Tag for save SET):** restaurado `0, null, null` para traer 558 modelos distintos de 9565 activos (meta 597 run 288) manteniendo `saveDataSuccessExecution: none` (no guarda `execution_data`). `Tag for save` (`JODxuGjfCJ2wDobA:38f549da`) de `Code runOnceForEachItem` a `Set 3.4` (7 campos por expresión, `includeOtherFields: false`) para evitar overhead del task runner; `Build save payload` queda `Code runOnceForAllItems` con `$input.all()`.

### Diagrama (simplificado)

```
When clicking 'Execute workflow'
      |
Execute login (Tryton login)
      |
Search assets ──→ Flatten assets
      |
Category list ──┐
Status list   ──┼──→ Split Out ──→ Execute categories/status ──→ Wait categories & statuses
                │                                              |
Model list    ──┘                                              ↓
                                        Execute models (lote, modo once) ──→ Prepare staging payload
                                                                          |
                                                            Execute ingest (batch)  ← sub-workflow §4.5
                                                                          |
                                                            Sync titular activo (v1)
```

Sub-workflow `Tryton sync snipe-IT assets ingest (batch)` (§4.5, detalle):

```
Reset staging (DELETE staging_tryton_assets)
      |
Load staging (bulk) (INSERT ... jsonb_to_recordset ON CONFLICT DO NOTHING)
      |
Diff assets (batch) (JOIN staging + model_map + status_map + asset_map)
      |
Any changes? ──→ Batch changes (splitInBatches)
      |
Create or update? ─┬─→ Create snipe-IT asset (POST /hardware)
                   └─→ Update snipe-IT asset (PATCH /hardware/{id})
                                |
                        Saved? ─┬─→ Upsert asset map (INSERT ... ON CONFLICT DO UPDATE)
                                └─→ Log error (batch) (INSERT integration_sync_log)
                                |
                        Run summary (INSERT sync_run_summary, executeOnce)
```

### Extraccion de activos

`Search assets` usa `model.asset.search_read` con:

- Dominio: `asset_type_new in [6, 39, 40, 48, 61, 92]`
- Offset: `0`, Limit: `100`
- **No hay paginacion**: solo se procesan los primeros 100 registros.

### Normalizacion (`Flatten assets`)

De cada registro se extrae:

```text
id, name, asset_state, code, internal_code,
actual_value (decimal), asset_model_id, asset_model_name,
current_owner_id, current_owner_name,
category, category_id, category_name
```

`category` se deriva del prefijo de `name` (texto antes de `:`), en mayusculas. Si no hay `:`, se usa `NO DEFINIDO`.

### Fase 2 — Batch PG (staging/diff/upsert) — vía sub-workflow

Fase 2 está delegada al sub-workflow `Tryton sync snipe-IT assets ingest (batch)` (§4.5). En el orquestador solo quedan:

1. **Prepare staging payload** (Code): construye `payload = [{tryton_asset_id, code, internal_code, name, asset_state, tryton_model_id, tryton_model_name, category_name}, …]` desde los activos aplanados y emite `{payload: JSON.stringify(rows), total}`.
2. **Execute ingest (batch)** (`n8n-nodes-base.executeWorkflow` → workflow `Asse2tIngestSub01`, inputs `{payload, total}`, `waitForSubWorkflow: true`).
3. **Sync titular activo** (`Execute Workflow` → `Tryton sync titular-activo (v1)`).

Detalle de los pasos internalizados (ver §4.5):

- `Reset staging` (`DELETE FROM staging_tryton_assets;`).
- `Load staging (bulk)` (`INSERT INTO staging_tryton_assets ... SELECT DISTINCT ON (tryton_asset_id) ... FROM jsonb_to_recordset($1) ON CONFLICT DO NOTHING` — `$1` = `$('Tryton sync snipe-IT assets orchestrator').first().json.payload`).
- `Diff assets (batch)` (`SELECT ... FROM staging_tryton_assets s JOIN tryton_snipe_model_map ... JOIN tryton_snipe_status_map ... LEFT JOIN tryton_snipe_asset_map ... WHERE IS DISTINCT` — `action='create'|'update'`).
- `Any changes?` → `Batch changes` (`splitInBatches`) → `Create or update?` → `Create/Update snipe-IT asset (batch)` (`POST/PATCH /api/v1/hardware`, `onError: continueRegularOutput`).
- `Saved?` → `Upsert asset map` / `Log error (batch)` (ambos `onError: continueRegularOutput`, loop-back a `Batch changes`) → `Run summary` (`executeOnce`, `INSERT INTO sync_run_summary ...`).

> **Refactor 2026-08-28 (ingest sub-workflow):** fase 2 extraída al sub-workflow `Asse2tIngestSub01` para mejorar mantenibilidad. El orquestador pasa `payload`/`total` vía `workflowInputs`; `Log error (batch)` en el sub registra `workflow_name` del sub y `execution_id` del sub (conteo `api_errors` de `Run summary` consistente dentro del sub).

### Enriquecimiento (fase 1, legacy)

Con `List all catalogs` (consulta a `tryton_snipe_model_map` y `tryton_snipe_status_map`) se construyen mapas en la versión previa sin staging. En v2 el enriquecimiento se hace vía SQL en `Diff assets (batch)` (joins contra `staging_tryton_assets`).

### Creacion de activos (`Create snipe-IT asset (batch)` / `Update snipe-IT asset (batch)`)

```json
POST /api/v1/hardware        // create
PATCH /api/v1/hardware/{id}  // update
{
  "name": "...",
  "asset_tag": "<code>",
  "status_id": 5,
  "model_id": 23
}
```

El body usa ids resueltos por `Diff assets (batch)` (`snipe_model_id`, `snipe_status_id` del map). Si falta mapeo, el activo se excluye en `missing_model` vía `Run summary` y no entra en `Batch changes` (el JOIN exige `m.snipe_model_id IS NOT NULL` y `st.snipe_status_id` existente).

---

## 4.2 Tryton sync categories

**Archivo:** `flows/flujos-dev/Tryton sync snipe-IT categories.json` (ID `Ps2wicy3xI4n37nD`)

### Entrada

```json
{ "category": "COMPUTADORAS" }
```

(Usa `inputSource: passthrough`.)

### Flujo

```
Search category (tryton_snipe_category_map where tryton_name)
      |
Exists category?
 +-- Si -> Finish
 +-- No -> Create snipe-it category
            |
        Is SnipeIT Created? ($json.body.status == "success")
         +-- Si -> Save SnipeIT Category (upsert)
         +-- No -> Find category in Snipe (GET /api/v1/categories?search=<name>)
                        |
                  Recover category (Code: normaliza respuesta)
                        |
                  Recovered category? ($json.found == true)
                   +-- Si -> Save SnipeIT Category (upsert)
                   +-- No -> Log error
```

### Detalles

- `POST /api/v1/categories` con `{ name, category_type: "asset" }`.
- `Full Response` activado: el IF usa `$json.body.status` y el upsert usa `$json.body.payload.*`.
- Upsert en `tryton_snipe_category_map`, matching por `tryton_name`.
- **Semantica:** `tryton_name` es el prefijo derivado del nombre del activo, no el ID de categoria de Tryton.
- **URL Snipe-IT:** usa `$env.SNIPE_HOST` (no hardcodeado).

### Self-heal: auto-recuperacion de categorias duplicadas

Cuando la creacion falla (ej: nombre duplicado -> HTTP 422), el flujo no termina en error. En vez de eso, busca la categoria existente en Snipe-IT por nombre y la mapea:

- `Find category in Snipe`: HTTP Request con `onError: continueRegularOutput` (si falla, devuelve `{ found: false }`)
- `Recover category`: Code node que busca el match exacto por nombre (case-insensitive) y construye el mismo formato de payload que la creacion exitosa
- `onError: continueRegularOutput` en `Find category in Snipe` significa que errores de conexion se capturan como item `[{"error": "..."}]` en vez de marcar el nodo en rojo

---

## 4.3 Tryton sync snipe-IT models

**Archivo:** `flows/flujos-dev/Tryton sync snipe-IT models.json` (ID `JODxuGjfCJ2wDobA`, inactivo) — invocado por el orquestador vía `Execute Tryton sync snipe-IT models` (modo once, `waitForSubWorkflow: true`).

**Entrada:** 1 item con el lote completo: `{ "result": [ {asset_model_id, asset_model_name, category}, ... ] }` (output de `Model list`, sin Split Out).

### Flujo

```
Tryton sync snipe-IT assets orchestrator ({ result: [modelos] })
      ↓
Resolve batch models (executeQuery, executeOnce:
  jsonb_to_recordset($1::jsonb) LEFT JOIN tryton_snipe_model_map
  LEFT JOIN tryton_snipe_category_map → jsonb_agg por modelo)
      ↓
Prepare items (Code runOnceForAllItems: descarta existentes sin cambio
  de nombre; emite pendientes con action "create"|"update"; sin pendientes
  emite 1 item `noop` para no vaciar la salida)
      ↓
Has work? (IF: $json.action != "noop")
   ├─ Sí → Create or update? (IF: $json.action == "create")
   │        ├─ create → Create snipe-it model (POST /models {category_id, name, fieldset_id:2}, batching 1/1200ms) → Is SnipeIT Saved?
   │        └─ update → Update snipe-it model (PATCH /models/{id} {name, fieldset_id:2}, batching 1/1200ms) → Is SnipeIT Saved?
  │                     ↓
   │                Is SnipeIT Saved? (body.status == "success")
   │                 ├─ Sí → Tag for save (Set por-item: $('Prepare items')+payload → tryton_model_id/tryton_name/snipe_model_id/snipe_category_id/snipe_name/created_at/updated_at) → Build save payload (Code runOnceForAllItems $input.all(), JSON)
   │                 │        → Save models (bulk) (INSERT ... jsonb_to_recordset ... ON CONFLICT (tryton_model_id) DO UPDATE, executeOnce) → Finish
   │                 └─ No → Find model in Snipe (rama self-heal, ver abajo)
   └─ No (noop) → Finish (garantiza ≥1 item para que Prepare staging payload corra)
```

### Self-heal: auto-recuperación de modelos duplicados

```
Is SnipeIT Saved? == false
      ↓
Find model in Snipe (GET /api/v1/models?search=<name>, onError: continueRegularOutput, fullResponse: true)
      ↓
Recover model (Code: match exacto case-insensitive por name)
      ↓
Recovered model? (found == true)
  ├─ Sí → Save model (self-heal) (upsert por-item) → Finish
  └─ No → Log error → Finish
```

- `Find model in Snipe`: `onError: continueRegularOutput` — en 401/500 devuelve `{error:{message,status}}` en vez de fallar
- `Recover model`: busca el match exacto y, en `found:false`, **propaga contexto de error** (`response_status`, `error_message`, `response_body`, `operation`, `request_payload`) para que `Log error` lo registre completo
- `Log error` lee todo desde `$json.*` del output de `Recover model` (no referencia nodos no ejecutados); el tryton_id sale de `$('Prepare items').item.json.asset_model_id`
- La rama self-heal queda por-item a propósito (solo corre en errores); el hot path es bulk: 1 ejecución + 2 queries PG + N HTTP (el HTTP es inherente, Snipe-IT no tiene bulk de models)
- Settings del workflow: `saveDataSuccessExecution: none` (con modo once ya no hay N sub-ejecuciones; se eliminan ~4.8 MB de `execution_data` por run)

> **Fix 2026-08-28:** `Log error` y `Recover model` tenían el mismo bug que `status` antes de su fix: `Log error` leía `$json.statusCode`/`$json.body.messages` sobre `{found:false}` y `operation` hardcodeado a `"create"` con `request_payload`/`response_body` que referenciaban `Create snipe-it model` directamente (vacío si la rama de `Update` ejecutó o si el error vino de `Find`/`Recover`). Fix: `Recover model` propaga `response_status`/`error_message`/`response_body`/`operation`/`request_payload` y `Log error` mapea `={{ $json.* }}`. Ver spec `.ai/specs/tryton-activos.md` § Tryton sync snipe-IT models.

> **Fix 2026-08-31 (0 pendientes bloqueaba fase 2):** `Prepare items` filtrado a 0 dejaba 0 de salida → el sub devolvía 0 → la fase 2 del orquestador no corría (`Prepare staging payload` sin datos). Ahora emite item `noop` y `Has work?` lo rutea a `Finish`; además el orquestador fija `alwaysOutputData: true` en `Execute models` y `Update snipe-it model` con `onError: continueRegularOutput`.

> **Fix 2026-08-31 (Build save payload):** `Build save payload` (Code `runOnceForAllItems`, `flows/flujos-dev/Tryton sync snipe-IT models.json:628`) usaba `$input.allItems()` — API inexistente → `TypeError: $input.allItems is not a function` (n8n 2.36.7, `JsTaskRunner.runForAllItems`). Fix: `$input.all().map(i => i.json)`; re-importar en n8n si se editó en la UI.

> **Fix 2026-08-31 (429 batching):** `Create/Update snipe-it model` sin `batching` → `429 Try spacing your requests out` (150/582 run 1101; 219/291 con `5/1000`). Fix: `options.batching.batch {batchSize:1, batchInterval:1200}` en ambos HTTP (`flows/flujos-dev/Tryton sync snipe-IT models.json:287,376`) + restart n8n; 558 modelos en ~670s (1/1.2s) sin 429.

> **Fix 2026-09-01 (self-heal models search=undefined):** `Find model in Snipe` usaba `encodeURIComponent($json.asset_model_name)`. Tras fallo de `Create` con `fullResponse: true` el item es `{body,statusCode,headers}` sin `asset_model_name` → `search=undefined` (`{"total":0}` verificado) y nunca encontraba el modelo existente. 40 duplicados Tryton (mismo `upper(trim(name))` ya sincronizado) quedaban sin mapeo (`tryton_snipe_model_map` 557/597, 40 `snipe_id=0` en `integration_sync_log`). Fix: `encodeURIComponent($('Prepare items').item.json.asset_model_name)` en `flows/flujos-dev/Tryton sync snipe-IT models.json:476` + `UPDATE workflow_entity JODxuGjfCJ2wDobA` + backfill SQL de los 40 al `snipe_model_id` canónico (557 `snipe_model_id` distintos, duplicados comparten Snipe-ID; 597/597 en map).

## 4.4 Tryton sync snipe-IT status

**Archivo:** `flows/flujos-dev/Tryton sync snipe-IT status.json` (ID `DFYH9aXY2QE6uJzl`, activo) — invocado por el orquestador vía `Execute Tryton sync snipeIT status` (uno por estado, `inputSource: passthrough` `{status}`).

### Flujo

```
Tryton sync snipe-IT assets orchestrator ({status})
      ↓
Execute login → Tryton status catalog → Tryton status list → Status asset
      ↓
Search status → Status exists? → Status up to date? / Create / Update → Is SnipeIT Saved?
      ↓ (false)
Find status in Snipe → Recover status → Recovered status? → Save SnipeIT Status / Log error
```

### Self-heal

`Find status in Snipe` usa `onError: continueRegularOutput` + `fullResponse:true`; en 401/500 devuelve `{error:{message,status}}`. `Recover status` propaga `response_status`/`error_message`/`response_body`/`operation`/`request_payload` y `Log error` los mapea con `={{ $json.* }}`. **Fix 2026-08-28:** antes `Log error` leía `$json.statusCode` sobre `{found:false}` y ternario sobre nodos no ejecutados → `operation` quedaba en `"\n  "`.

---

## 4.5 Tryton sync snipe-IT assets

**Archivo:** `flows/flujos-dev/Tryton sync snipe-IT assets.json` (ID `v6K5kipkr7UKp0fE`, activo — **canónico**; el archivo `ingest (batch).json` `Asse2tIngestSub01` era un snapshot stale duplicado del mismo workflow y fue eliminado) — invocado por el orquestador vía `Execute ingest (batch)` (`waitForSubWorkflow: true`, workflow `v6K5kipkr7UKp0fE`).

**Trigger:** `Tryton sync snipe-IT assets orchestrator` (`n8n-nodes-base.executeWorkflowTrigger`, `inputSource: passthrough`, antes `Tryton sync snipe-IT assets orchestrator`).

**Entrada:** `{ "payload": "<json-array-string>", "total": 100 }` desde `Prepare staging payload` del orquestador (`payload = JSON.stringify(rows)` donde cada row es `{tryton_asset_id, code, internal_code, name, asset_state, tryton_model_id, tryton_model_name, category_name}`).

### Flujo

```
Tryton sync snipe-IT assets orchestrator ({payload, total})
      ↓
Check custom field internal_code (GET /api/v1/fields)
      ↓
Has internal_code field? (IF ($json.rows ?? []).some(f => f.db_column_name === '_snipeit_internal_code_2'))
  ├─ false → Fail: missing custom field (Stop and Error) → "Falta _snipeit_internal_code_2. Ejecute ./scripts/snipe-it_custom_fields.sh"
  └─ true  → Reset staging (DELETE FROM staging_tryton_assets;)
                ↓
             Load staging (bulk) (INSERT INTO staging_tryton_assets ... SELECT DISTINCT ON (tryton_asset_id) ... FROM jsonb_to_recordset($1) ON CONFLICT DO NOTHING — $1 = $('Tryton sync snipe-IT assets orchestrator').first().json.payload)
                ↓
             Diff assets (batch) (SELECT ... FROM staging_tryton_assets s JOIN tryton_snipe_model_map m ON ... JOIN tryton_snipe_status_map st ON ... LEFT JOIN tryton_snipe_asset_map am ON ... WHERE IS DISTINCT — calcula action='create'|'update')
                ↓
              Any changes? (IF $json.action notEmpty)
               ├─ true  → Batch changes (splitInBatches, **batchSize 1** secuencial — deliberado para no disparar `429 api-throttle:api`; ver micro-nota 1×1)
               │              ↓ (done)           ↓ (each)
               │           Run summary        Create or update? (IF $json.action == 'create')
               │           (ver guarda        ├─ true  → Create snipe-IT asset (batch) (POST /api/v1/hardware {name, asset_tag, status_id, model_id, _snipeit_internal_code_2}, onError: continueRegularOutput, fullResponse: true)
               │            post-loop)       └─ false → Update snipe-IT asset (batch) (PATCH /api/v1/hardware/{snipe_asset_id} {name, asset_tag, status_id, model_id, _snipeit_internal_code_2}, onError: continueRegularOutput, fullResponse: true)
                │                                              ↓
                │                                           Saved? (IF body.status == "success", antes `Saved?`)
                │                                            ├─ true  → Upsert asset map (INSERT INTO tryton_snipe_asset_map ...) → Loop → Batch changes
                │                                            └─ false → Find asset in Snipe (GET /api/v1/hardware?asset_tag={{code}}, `encodeURIComponent($('Batch changes').item.json.code)`, fullResponse, onError: continueRegularOutput)
                │                                                         ↓
                │                                                      Recover asset (Code: match exact `asset_tag` en `body.rows`, `deleted_at is null`; encontrado → {found:true, payload}; no → propaga `response_status`/`error_message`/`response_body`/`operation` del Create/Update)
                │                                                         ↓
                │                                                      Recovered asset? (IF $json.found, antes `Recovered asset?`)
                │                                                        ├─ true  → Upsert asset map → Loop → Batch changes
                │                                                        └─ false → Log error (batch) → Loop → Batch changes
               └─ false → Without changes → Continue → Run summary (INSERT INTO sync_run_summary ...) → Has API errors? (IF ($json.api_errors ?? 0) > 0) → true: Fail: ingest had API errors / false: Finish
```

- `Tryton sync snipe-IT assets orchestrator` (antes `Tryton sync snipe-IT assets orchestrator`) — trigger `executeWorkflowTrigger`.
- `Check custom field internal_code` / `Has internal_code field?` / `Fail: missing custom field`: **pre-flight** (Cap. 1). Verifica `GET /api/v1/fields` y que exista `db_column_name === '_snipeit_internal_code_2'` (id 2). Si falta, falla en ~1 s con mensaje accionable (`ejecute ./scripts/snipe-it_custom_fields.sh`) en vez de procesar 8k assets 50 min para que todos fallen con `_snipeit_internal_code_2 does not seem to exist`. *Prerequisito:* `scripts/snipe-it_custom_fields.sh` (idempotente).
- `Reset staging` → `Load staging (bulk)` (`jsonb_to_recordset($1)` `$1 = $('Tryton sync snipe-IT assets orchestrator').first().json.payload`, `DISTINCT ON tryton_asset_id`, `ON CONFLICT DO NOTHING`) → `Diff assets (batch)` (`JOIN tryton_snipe_model_map/status_map ⟕ asset_map`, `action ∈ {create,update}`) → `Any changes?` → `Without changes` (keep-alive ≥1 item) → `Continue` (Cap. 2 y 5).
- `Batch changes` (antes `Batch changes`, splitInBatches, **batchSize 1**) — ver micro-nota 1×1; `Create or update?` → `Create`/`Update snipe-IT asset (batch)` (Cap. 3).
- `Find asset in Snipe` / `Recover asset` / `Recovered asset?` (antes `Recovered asset?`): **self-heal assets** (Cap. 3, micro-nota Recover). Cuando `Create/Update` falla (`asset_tag must be unique` por 383 huérfanos), busca por `asset_tag` exacto (`GET /api/v1/hardware?asset_tag=X`, `=`) y si lo encuentra normaliza `body.payload` → `Upsert asset map` (`Recover` propaga `tryton_id`/`operation` y `Log error` lee `$json.*`). La re-ejecución corrige los huérfanos sin SQL manual.
- `Has API errors?` / `Fail: ingest had API errors`: **guarda post-loop** (Cap. 4, micro-nota gate). Tras `Run summary`, si `api_errors > 0` el sub pasa a `error` (visible en n8n) en vez de `success` engañoso. `Loop` (antes `Loop`) es noOp puente hacia `Batch changes`; `Finish` es éxito. `Log error` lee `$json.*` propagado por `Recover` (no `$('Batch changes').item` cruzado).
- `Create/Update snipe-IT asset (batch)`: `batchSize:1, batchInterval:1200` + `retryOnFail (4×3s)` + `onError: continueRegularOutput` + `fullResponse` — evita `429` (throttle 60/min) y reintenta. `Find asset in Snipe` con mismo batching 1/1200 + retry 3×2s.
- `Upsert asset map` mapea `$('Batch changes').item.json.*` + `$json.body.payload.*`; `Log error` usa `$json.tryton_id`/`$json.operation`/`$json.response_status` de `Recover asset`.
- **Refactor 2026-08-28:** extraído del orquestador para mejorar mantenibilidad. `workflow_name` en `integration_sync_log` pasa a ser el nombre del sub-workflow (decisión acordada).
- **Libro abierto 2026-09-03:** 5 headers Cap. 1–5 + 4 micro-notas (1×1 anti-429, keep-alive, Recover, gate) y 7 nodos revisados manteniendo inglés (`Tryton sync snipe-IT assets orchestrator`, `Batch changes`, `Loop`, `Without changes`, `Continue`, `Saved?`, `Recovered asset?`) con aclaraciones ` (1×1)` y notas y 5 expresiones `$()` sincronizadas; stale `ingest (batch).json` (`Asse2tIngestSub01`) eliminado, canónico `assets.json` `v6K5kipkr7UKp0fE` 35 nodos. *Revisión tarde:* traducciones a español revertidas — nombres se mantienen en inglés por convención.

> **Fix 2026-09-01 (custom field internal_code faltante — 0 assets):** orquestador 1265 / ingest 1266 (`success` pero 0 assets). Fix: añadida guarda pre-flight y guarda post-loop + script `scripts/snipe-it_custom_fields.sh` idempotente; re-export snapshot (21 nodos con Loop/Finish).

> **Fix 2026-09-01 (self-heal assets — 383 huérfanos tras cancelación):** cancelación a mitad de loop dejó 383 assets en Snipe sin map (`Upsert` no llegó). Sin self-heal la re-ejecución reintentaba `create` → `asset_tag must be unique` perpetuo. Fix: añadidos `Find asset in Snipe` → `Recover asset` → `Recovered asset?` → `Upsert asset map` en rama `Saved? false`. Snapshot 21→24 nodos; sin duplicados de `code` en staging verificado (0).

> **Fix 2026-09-05:** corrida 266 (`error`, 4751s, 9518 to_create / 71 api_errors, map 9369): `1/550ms` (~109/min) supera el cap 60/min en lote completo y `Find` sin batching duplicaba la tasa en fallos → 71× `429 Try spacing your requests out` tras 4×3s. Fix: `Create/Update` a `1/1200` (~50/min) + `Find` con `1/1200` (`flows/flujos-dev/Tryton sync snipe-IT assets.json` + `UPDATE workflow_entity ym0zaIpEj3J8xg2l` + restart n8n). Re-run procesa los ~149 restantes.

---

## 4.6 Tryton sync titular-activo (v1)

**Archivo:** `flows/flujos-dev/Tryton sync users assets.json` (ID `Yv8AlEkGEdwzRJrJ`, activo) — invocado por el orquestador vía `Sync titular activo` (`waitForSubWorkflow: true`). También corre manual.

**Fuente autoritativa:** empleados activos con contrato vigente (`res_user.login` → `login@guayas.gob.ec`).

### Flujo

```
Iniciar sesión en Tryton (Cnq2yvzVCRTKFld5) → Leer activos con titular (retry 3×3s) → Extraer activos y titulares (dedup owner_ids)
     → Consultar empleados activos (ERP) (DISTINCT ON pp.id, contrato más reciente) → Estado deseado (login → {snipe_asset_tag, email})
     → Limpiar tabla temporal (staging) → Cargar titulares en staging (jsonb_to_recordset)
     → Precargar usuarios de Snipe-IT (GET /users?limit=500, 1 req) → Guardar mapa de usuarios (bulk) (jsonb_to_recordset ON CONFLICT DO UPDATE)
      → Calcular usuarios faltantes (DISTINCT ON LOWER(email) no en mapa) → ¿Hay usuarios faltantes? → Extraer usuarios faltantes (1 por email) → Preparar datos del nuevo usuario → Crear usuario en Snipe-IT (POST /users) → Registrar usuario creado → ¿Tiene ID? → Guardar usuario creado en mapa (BD) ┐ ↘ Usuarios listos (colapsa M→1, 45 nodos) →┐
                                               ↓ false ────────────────────────────────────────────────────────────┘ sin id → Marcar ID faltante (status error) ──┘                                ↓
                                                                    Reintentar con username alternativo (POST sufijo) → Registrar usuario creado (alt) → ¿Tiene ID? → Guardar usuario creado en mapa (BD) →┘ | error alt → Marcar error al crear usuario →┘ | sin id → Marcar ID faltante →┘ (fan-in 3→1: Save + Mark Create Failed + Mark Missing ID) ↓
                                                             Contar activos sin mapeo (staging sin asset_map)
     → Detectar cambios de titular (JOIN asset_map + LEFT JOIN snipe_titular_map + LEFT JOIN snipe_titular_user_map ON LOWER(s.email) WHERE s.email<>'' AND IS DISTINCT)
     → ¿Titular ya mapeado en BD? (IF existing_user_id) → Preparar asignación (Set: snipe_user_id = existing_user_id, created_user = false, + current_user_id) ──┐
                                         ↓ false → Marcar usuario no disponible (Set, status error) ──┐
                                                                                                     ↓ (fan-in 2→1)
                                                                                                  Preparar asignación (Set, 1 inbound: rama ok) → ¿Necesita checkin? (IF current_user_id: true→checkin directo, false→checkout optimista) → Asignar activo al titular (checkout) (POST /checkout) → Registrar asignación exitosa (Set) ──┐
                                                                                                                                                  ↓ error → Liberar activo (checkin) (POST /checkin) → Reintentar asignación → Registrar asignación exitosa (tras reintento) (Set) ─┤
                                                                                                                                                                                        ↓ error → Registrar error de asignación (Set) ─┤
                                                                                                                                                                                                                               ↓ (fan-in 4→1: ok + ok reintento + error checkout + usuario no disponible)
                                                                                                                                                                                                                                                                                                                                                                                                                         Package Results (Code, fan-in 4→1 → {payload, total, ok, errores, usuarios_nuevos}, 8000 items → 1)
         ↓ (fan-out 1→4, bulk)
   ┌──────────────┬──────────────────────┬─────────────────┐
   ↓              ↓                      ↓                 ↓
 Guardar usuarios en mapa (bulk)  Guardar titulares en mapa (bulk)  Registrar errores en bitácora (bulk)  Calcular resumen de sincronización (Code: lee $('Package Results').first().json.{ok,errores,usuarios_nuevos} → {cambios, aplicados, errores, omitidos, usuarios_nuevos})
 (INSERT ... jsonb_to_recordset($1)     (INSERT ... jsonb_to_recordset($1)            (INSERT ... jsonb_to_recordset($3)                              ↓
  WHERE status='ok' DISTINCT ON(email)   WHERE status='ok' DISTINCT ON(tag)           WHERE status='error'                                   Guardar resumen en bitácora (INSERT integration_sync_log operation='run_summary')
```

- `Extraer activos y titulares` (Code, `runOnceForAllItems`): recibe 1 item con `result` completo del `search_read`; en una pasada filtra `current_owner != null`, construye `assets: [{code, owner_id}]` (para `Construir titulares deseados`) y deduplica `owner_ids: [...new Set(...)]` (para `Consultar empleados activos (ERP)` `= ANY($1)`); emite `n_assets`/`n_owners`. No es un `Set` porque requeriría duplicar `filter/map` y la dedup en expresión es ilegible — se mantiene como Code intencionalmente.
- `Iniciar sesión en Tryton` con ambos triggers confluyendo; `Leer activos` con `retryOnFail 3×3s` cubre 429 de Tryton (un solo `search_read` `0,null,null` sobre ~19k).
- `Detectar cambios de titular` filtra `tm IS NULL` o `email IS DISTINCT FROM s.email`; excluye `snipe_asset_id IS NULL` (omitidos contados aparte).
- **Precarga bulk de usuarios (Fase A, antes del diff):** `Precargar usuarios de Snipe-IT` (Code node, paginado: offset 0/500/1000, break si `<500`) → `Guardar mapa de usuarios (bulk)` (`INSERT ... jsonb_to_recordset($1) WHERE x.email<>'' ON CONFLICT (email) DO UPDATE`) → `Calcular usuarios faltantes` → `¿Hay usuarios faltantes?` → `Extraer usuarios faltantes` (1 por email) → `Preparar datos del nuevo usuario` → `Crear usuario en Snipe-IT` (`POST /api/v1/users`, batching 1/1200ms) → `Tag New User` (`snipe_user_id` con fallback) → `¿Es error de duplicado?` (`Is Duplicate Error?`, `$json.body.status == "error"`): true→`Find User in Snipe` → `Recover User` → `Save New User` (upsert); false→`¿Tiene ID?` → `Guardar usuario en mapa` / `Marcar ID faltante`. Self-heal en colisión username → `Retry Alt` → `Tag` → `Is Duplicate Error?` → ... `Usuarios listos` (Code colapsa M→1). Rama `false` del IF va directo a `Contar activos sin mapeo`. **Eliminados 2026-09-03:** `Buscar usuario por email en Snipe-IT`, `¿Usuario existe en Snipe-IT?`, `Usar usuario existente de Snipe-IT`.
- `¿Titular ya mapeado en BD?` / `Preparar asignación` / `Marcar usuario no disponible`: resuelven `snipe_user_id` **sin HTTP**. Si `existing_user_id` existe (cache tras precarga+creación) → `Preparar asignación` (`snipe_user_id = existing_user_id ?? snipe_user_id`, `created_user = false`, + `current_user_id` para ruteo); si no → `Marcar usuario no disponible` (`status error`, sin checkout). **Nodo eliminado 2026-09-04:** `Use Mapped User` (ver Fix abajo). `Detectar cambios de titular` añade guarda `s.email<>''` y join `LOWER(s.email)`.
- `Preparar asignación` (Set, 1 inbound: rama ok de `Owner Mapped?` — absorbe el rename `existing_user_id`→`snipe_user_id` del eliminado `Use Mapped User`) + `current_user_id` → IF `Needs Checkin?` (`current_user_id` notEmpty: true→`Checkin Asset` directo, false→`Checkout Asset` optimista, fallback intacto) → `Asignar activo al titular (checkout)` (`POST /api/v1/hardware/{id}/checkout` `{checkout_to_type:user, assigned_user, note}`, `retryOnFail 3×2s`, `batching 1/1200ms`, `onError: continueErrorOutput` → `Registrar asignación exitosa`) en error → `Liberar activo (checkin)` (`POST /checkin`, `onError: continueRegularOutput`) → `Reintentar asignación` (`batching 1/1200ms`) → `Registrar asignación exitosa (tras reintento)` / `Registrar error de asignación` (`status error`).
- `Package Results` (Code, `runOnceForAllItems`, fan-in 4→1 de `Registrar asignación exitosa` + `Registrar asignación exitosa (tras reintento)` + `Registrar error de asignación` + `Marcar usuario no disponible` → 1 item `{payload, total, ok, errores, usuarios_nuevos}` con `payload=JSON.stringify(rows)`). Contrato de 1 item: los 3 nodos bulk leen `$('Package Results').first().json.payload` y filtran por `status` en SQL.
- `Guardar usuarios en mapa (bulk)` (`INSERT INTO snipe_titular_user_map ... SELECT DISTINCT ON (x.email) ... FROM jsonb_to_recordset($1::jsonb) AS x(...) WHERE x.status='ok' ORDER BY x.email ON CONFLICT (email) DO UPDATE`) y `Guardar titulares en mapa (bulk)` (ídem por `snipe_asset_tag`) + `Registrar errores en bitácora (bulk)` (`INSERT INTO integration_sync_log ... SELECT $1,$2 ... FROM jsonb_to_recordset($3::jsonb) WHERE x.status='error'`). Eliminado `¿Asignación exitosa?` (filtro en `WHERE`).
- `Calcular resumen de sincronización` (lee `Package Results` stats `ok/errores/usuarios_nuevos` + `Detectar cambios` `all().length` + `Contar activos sin mapeo` `omitidos`) → `Guardar resumen en bitácora` deja siempre una fila `run_summary` (`entity='titular'`) con `{cambios, aplicados, errores, omitidos, usuarios_nuevos}`.
- No revoca checkouts (intencional, ver §4.8). Tablas: `staging_titular`, `snipe_titular_user_map`, `snipe_titular_map`.

> **Fix 2026-09-01 (referencia huérfana + SNIPE_TOKEN + TRYTON_HOST):** `Iniciar sesión en Tryton` → `RuVLU1TOMoOxqVE3` (borrado) → `Cnq2yvzVCRTKFld5`; `Aplicar` usaba `SNIPE_TOKEN` inexistente → 401 masivo (200/0/200×401); `Leer activos` usaba `TRYTON_HOST` vs `TRYTON_URL`. Fix repuntado + alineado a `SNIPEIT_TOKEN || SNIPE_TOKEN` y `TRYTON_URL || TRYTON_HOST` + retry en Code. Ver `flows/flujos-dev/Tryton sync users assets.json:45,89,228`.

> **Fix 2026-09-01 (observabilidad):** antes errores solo en `staticData.lastRun` (no persistente). Fix: `status ok|error` + IF `¿Asignación exitosa?` → `Registrar error en bitácora` (`titular_checkout`) + `Contar activos sin mapeo`/`Resumen/Log resumen` (`run_summary` titular). Snapshot 15→19 nodos.

> **Decisión 2026-09-01 (no-revocación):** solo asigna/reasigna; si `current_owner=null` el activo queda con titular anterior. Pendiente política de `checkin` automático.

> **Fix 2026-09-02 (settings de ejecución):** workflow creado sin `saveDataSuccessExecution: none` (los otros 3 workflows sí lo tenían desde el fix 2026-08-31); cada corrida guardaba ~10 nodos × 8000 items en `execution_entity` (~10-30 MB) y congelaba el navegador. Fix: `settings` alineados a `status`/`models`/`ingest` vía `UPDATE workflow_entity SET settings WHERE id='yjyUYjVEaZ9UniSs'` + `docker compose restart n8n` y snapshot sincronizado; ID corregido de `nocNCHrMCVe36Qxr` a `yjyUYjVEaZ9UniSs`.

> **Fix 2026-09-02 (cola DB bulk, 16k→3 queries):** `Consolidar resultados` (8000 items) alimentaba `¿Asignación exitosa?` (IF ×8000) → `Guardar usuario/titular en mapa (BD)` (2×8000 queries) + `Registrar error en bitácora` (N queries). Fix: `Package Results` (Code, 8000→1) + 3 queries bulk con `jsonb_to_recordset($1) WHERE status=...` + `DISTINCT ON` + `ON CONFLICT DO UPDATE` (sin `cannot affect row a second time` por email repetido). Eliminado `¿Asignación exitosa?` (filtro en `WHERE`). Snapshot 45→44 nodos, `UPDATE workflow_entity yjyUYjVEaZ9UniSs` + `restart n8n`; spec y `docs/04` §4.6 sincronizados.

> **Fix 2026-09-03 (Save New User null snipe_user_id — `andrea.sanchez@guayas.gob.ec`):** `Save New User` (`INSERT INTO snipe_titular_user_map(email, snipe_user_id) VALUES ($1,$2)`, `Tryton sync users assets.json:1495`, `snipe_user_id INTEGER NOT NULL`) falló `null value violates not-null constraint` fila `(andrea.sanchez@guayas.gob.ec, null, 2026-09-03)` (`3/9/2026 3:47:46 p. m.` `Postgres` `executeQuery`). `Tag New User`/`(Alt)` solo leían `$json.body.payload.id`; si Snipe responde 200 `{"status":"error",...}` o `body.id`/`data.id`, el `id` queda `null` y el `INSERT` por item aborta (0 filas para ese email, `Users Ready` no llega a `Count Unmapped`). Fix: fallback `{{ $json.body?.payload?.id ?? $json.body?.id ?? $json.body?.data?.id ?? $json.payload?.id ?? $json.id }}` + IF `Has User ID?` (`snipe_user_id` isNotEmpty) entre `Tag` y `Save New User`: true→`Save`, false→`Mark Missing ID` (`status error`) → `Users Ready` (fan-in 3→1, 46 nodos, `Save New User` `[8032,2176]`). Un email malo ya no tumba la corrida; queda vía `Mark No User`→`Log Errors (bulk)`. Espejo de `.ai/specs/tryton-activos.md`.

> **Fix 2026-09-03 (Bulk Save Users sin DISTINCT ON):** `Bulk Save Users` con 74 filas de `Preload Snipe Users` contenía 2 emails duplicados (`christian.calderon@guayas.gob.ec` 12/73, `manuel.paez@guayas.gob.ec` 30/74) → `ON CONFLICT DO UPDATE cannot affect row a second time` en `Bulk Save Users` (precarga bulk sin `DISTINCT ON`). Fix: `SELECT DISTINCT ON (LOWER(x.email)) ... ORDER BY LOWER(x.email), x.id` (id menor) en `Bulk Save Users` (`Tryton sync users assets.json`), `UPDATE workflow_entity` + `restart n8n`; dry-run `BEGIN; ... ROLLBACK;` verificó 72 inserts.

> **Fix 2026-09-02 (task runner timeout 300s):** `Consolidar resultados` (Code `runOnceForAllItems` con `helpers.httpRequest` + `sleep(1500)` en bucle `for...await` sobre N filas) superaba `N8N_RUNNERS_TASK_TIMEOUT=300s` (n8n 2.36.7 `TaskBroker.handleTaskTimeout`). Refactor a nodos nativos (ver flujo arriba, 19→37 nodos, todos `httpBearerAuth` `Adhjdtilu8D9eQs8`, `retryOnFail`/`onError` nativos, `batching 20/500ms`); corre en proceso principal sin límite del runner. Snapshot `flows/flujos-dev/Tryton sync users assets.json`.

> **Fix 2026-09-03 (precarga bulk titulares):** `Buscar usuario por email en Snipe-IT` (`GET /api/v1/users?email=&limit=1`, `batching 20/500ms`) con 8,991 items y `snipe_titular_user_map` vacío → 8,991 GETs, **96 éxito y 8,895 error (8,541 `timeout of 30000ms`, resto `ETIMEDOUT`/`ECONNRESET`/`EAI_AGAIN`)** en ejecución 1487, `executionTime` 2,991,056 ms (~50 min), Snipe-IT 804% CPU y DNS `EAI_AGAIN`; cada corrida repetía el costo. Además 74 usuarios en Snipe vs 698 emails distintos; `email=''` → falso match; 1 creación por *asset* (no por email) → ~13 intentos duplicados por email. Fix: precarga bulk antes del diff — `Precargar usuarios de Snipe-IT` (1 GET `/api/v1/users?limit=500`) → `Guardar mapa de usuarios (bulk)` (`jsonb_to_recordset($1) LOWER(email)`) → `Calcular usuarios faltantes` (`DISTINCT ON LOWER(email)` no en mapa) → `¿Hay usuarios faltantes?` → `Extraer usuarios faltantes` (1 por email) → `Crear usuario`/`Reintentar alt` → `Guardar usuario creado en mapa (BD)` + `Usuarios listos` (colapsa M→1); rama `false` directa a `Contar activos sin mapeo`. `Detectar cambios` con guarda `s.email<>''` y join `LOWER(s.email)`. `¿Titular ya mapeado en BD?` sin HTTP: `true`→`Usar usuario del mapa`, `false`→`Marcar usuario no disponible`→`Consolidar resultados`. Eliminados 3 nodos de búsqueda. Snapshot 37→45 nodos, `UPDATE workflow_entity yjyUYjVEaZ9UniSs` + `docker compose restart n8n`; spec `.ai/specs/tryton-activos.md` sincronizado.

---

> **Fix 2026-09-03 (nombres EN — Tryton sync users assets):** snapshot `Tryton sync users assets.json` (ID `yjyUYjVEaZ9UniSs`, mismo workflow que `titular-activo`, 45 nodos) renombró 39 nodos funcionales de ES a EN corto Title Case sin mover `position`/`id`/`type`/`credentials`/`settings`. Trigger `Tryton sync snipe-IT assets orchestrator` y 5 stickies (`Sticky Note*`, `Capítulo 3: Aplicar en Snipe-IT`) se mantuvieron ES. Conexiones y `$('...')` (`Extract Asset Owners`, `Build Owners`, `Preload Snipe Users`, `Prep New User`, `Prep Assignment`, `Merge Results`, `Detect Changes`, `Count Unmapped`) actualizadas. Mapeo: `Iniciar sesión en Tryton`→`Tryton Login`, `Leer activos con titular`→`Read Owned Assets`, `Extraer activos y titulares`→`Extract Asset Owners`, `Consultar empleados activos (ERP)`→`Query Active Employees`, `Construir titulares deseados`→`Build Owners`, `Limpiar tabla temporal (staging)`→`Clear Staging`, `Cargar titulares en staging`→`Stage Owners`, `Precargar usuarios de Snipe-IT`→`Preload Snipe Users`, `Guardar mapa de usuarios (bulk)`→`Bulk Save Users`, `Calcular usuarios faltantes`→`Find Missing Users`, `¿Hay usuarios faltantes?`→`Missing Users?`, `Extraer usuarios faltantes`→`Get Missing Users`, `Preparar datos del nuevo usuario`→`Prep New User`, `Crear usuario en Snipe-IT`→`Create Snipe User`, `Registrar usuario creado`→`Tag New User`, `Reintentar con username alternativo`→`Retry Alt Username`, `Registrar usuario creado (alt)`→`Tag New User (Alt)`, `Marcar error al crear usuario`→`Mark Create Failed`, `Guardar usuario creado en mapa (BD)`→`Save New User`, `Usuarios listos`→`Users Ready`, `Contar activos sin mapeo`→`Count Unmapped`, `Detectar cambios de titular`→`Detect Changes`, `¿Titular ya mapeado en BD?`→`Owner Mapped?`, `Usar usuario del mapa`→`Use Mapped User`, `Marcar usuario no disponible`→`Mark No User`, `Preparar asignación`→`Prep Assignment`, `Asignar activo al titular (checkout)`→`Checkout Asset`, `Registrar asignación exitosa`→`Checkout OK`, `Liberar activo (checkin)`→`Checkin Asset`, `Reintentar asignación`→`Retry Checkout`, `Registrar asignación exitosa (tras reintento)`→`Checkout OK (Retry)`, `Registrar error de asignación`→`Checkout Failed`, `Consolidar resultados`→`Merge Results`, `¿Asignación exitosa?`→`Checkout OK?`, `Guardar usuario en mapa (BD)`→`Upsert User`, `Guardar titular en mapa (BD)`→`Upsert Owner`, `Registrar error en bitácora`→`Log Error`, `Calcular resumen de sincronización`→`Build Summary`, `Guardar resumen en bitácora`→`Save Summary`. Validado: 45 nodos, 0 refs ES, diff `position` vacío. Espejo en `.ai/specs/tryton-activos.md`.

> **Fix 2026-09-04 (fusión Use Mapped User → Prep Assignment):** `Use Mapped User` (Set: passthrough + rename `existing_user_id`→`snipe_user_id`) y `Preparar asignación`/`Prep Assignment` (Set: passthrough puro) corrían en serie sin lógica adicional. Fix: eliminado `Use Mapped User`; `Prep Assignment` absorbe el rename (`existing_user_id ?? snipe_user_id`, `created_user=false`) y `Owner Mapped?` true va directo a él. Snapshot 46→45 nodos, `UPDATE workflow_entity yjyUYjVEaZ9UniSs` sin restart. Mismo día, higiene: recortados `snipe_asset_tag`/`snipe_asset_id` de `Prep New User` (huérfanos, siempre fallback, sin lectores aguas abajo) — 5 assignments, ancla intacta, `UPDATE` solo de `nodes`. Espejo de `.ai/specs/tryton-activos.md`.

> **Fix 2026-09-04 (ruteo Needs Checkin? + medición C):** Medición: sin emails de checkout (0/30 categorías), sin webhooks, API ~400ms < intervalo 1200ms → sin tuning lado Snipe-IT. Diff pendiente: 1739 primeras asignaciones (0 reasignaciones) → el ruteo ahorra ~1 request por reasignación en steady-state. Nuevo IF `Needs Checkin?` (`current_user_id` notEmpty): true→`Checkin Asset` directo, false→`Checkout Asset` optimista (fallback intacto). 46→47 nodos, `UPDATE workflow_entity yjyUYjVEaZ9UniSs` sin restart. Espejo de `.ai/specs/tryton-activos.md`.

> **Fix 2026-09-04 (Has User ID? strict→loose + throttling 1/1200 + Mark No User):** ejecución 1508 (`error`, `Has User ID?` `Wrong type: '1052' is a number but was expecting a string`, rama `Tag New User (Alt)`): IF `number` `notEmpty` con `typeValidation: strict` abortaba ante IDs numéricos → `Save New User` 0 runs, 226 emails sin crear → 1747 `Mark No User`; checkout parcial (1552+859) sí persistió. Además 4 HTTP (`Create`/`Retry Alt`/`Checkout`/`Retry Checkout`) con `batchSize: 5` sin intervalo → 954× `429` (cap Snipe-IT 120/min); `Mark No User` con literal `'{{$json.email}}'` sin `={{ }}` (1747 filas sin email). Fix: `Has User ID?` + `Owner Mapped?` a `typeValidation: loose`; 4 HTTP a `batchSize: 1, batchInterval: 1200` (~50/min); `Mark No User` a `={{ '...' + $json.email + ')' }}`. `UPDATE workflow_entity yjyUYjVEaZ9UniSs` + `restart n8n`; snapshot sincronizado. Conocido que queda: `Package Results` corre 1 vez por rama activa (4× `run_summary` por ejecución); verdad por ejecución = `SUM(aplicados)`, `SUM(errores)`, `MAX(cambios)` por `execution_id`.

## 4.7 Tablas de mapeo

Tablas en PostgreSQL (BD de n8n).

### `tryton_snipe_category_map`

| Columna | Notas |
|---------|-------|
| `tryton_name` | Clave (prefijo derivado del nombre del activo) |
| `snipe_category_id` | ID en Snipe-IT |
| `snipe_name` | Nombre en Snipe-IT |
| `created_at`, `updated_at` | Fechas |

### `tryton_snipe_model_map`

| Columna | Notas |
|---------|-------|
| `tryton_model_id` | Clave |
| `tryton_name` | Nombre en Tryton (se actualiza) |
| `snipe_model_id` | ID en Snipe-IT |
| `snipe_name` | Nombre actual en Snipe-IT |
| `snipe_category_id` | ID de categoria Snipe-IT |
| `created_at`, `updated_at` | Fechas |

### `tryton_snipe_status_map`

| Columna | Notas |
|---------|-------|
| `tryton_name` | Clave (estado Tryton) |
| `snipe_status_id` | ID del status label |
| `snipe_name` | Nombre en Snipe-IT |
| `status_type` | `deployable`, `pending`, `archived` |
| `created_at`, `updated_at` | Fechas |

### `integration_sync_log`

Auditoría en `public.integration_sync_log` (BD `n8n`).

- **Status flow:** `Log error` mapea `operation`/`request_payload`/`response_status`/`response_body`/`error_message` desde `Recover status` (propaga error context). **Fix 2026-08-28** corrigió lecturas vacías sobre `{found:false}`.
- **Models flow:** `Log error` mapea `operation`/`request_payload`/`response_status`/`response_body`/`error_message` desde `Recover model` (propaga error context). **Fix 2026-08-28:** antes leía `$json.statusCode`/`$json.body.messages` sobre `{found:false}` y `operation` hardcodeado a `"create"` con `request_payload`/`response_body` que referenciaban `Create snipe-it model` directamente.
- **Categories flow:** `operation` hardcodeado a `"create"`; `request_payload` es `JSON.stringify(params.bodyParameters.parameters[1])`.
- **Titular flow:** `Registrar error en bitácora` (`titular_checkout` por cada `status=error`) y `Guardar resumen en bitácora` (`run_summary` `entity='titular'` con `{cambios, aplicados, errores, omitidos, usuarios_nuevos}`) — auditoría siempre. **Fix 2026-09-01:** antes solo `staticData.lastRun`.
- **General:** `tryton_id`/`snipe_id` en `0` para categorías/estados/titular; sin mapa de activos ni reconciliación.

### `staging_tryton_assets` — orquestador v2 (batch)

Tabla efímera por ejecución. `DELETE` al inicio y `INSERT` masivo desde `jsonb_to_recordset`. Esquema en `public.staging_tryton_assets` (BD `n8n`). **Fix 2026-08-28:** no existía; los nodos `Reset staging`, `Load staging (bulk)`, `Diff assets (batch)` y `Run summary` fallaban con `relation "staging_tryton_assets" does not exist`. Añadida a `sql/init-sync-tables.sql` §5.

| Columna | Notas |
|---------|-------|
| `tryton_asset_id` | Clave (UNIQUE, target de `ON CONFLICT DO NOTHING`) |
| `code` | `asset_tag` en Snipe-IT |
| `internal_code` | Código interno Tryton |
| `name` | Nombre del activo |
| `asset_state` | Estado Tryton — join con `tryton_snipe_status_map.tryton_name` |
| `tryton_model_id` | FK lógico a `tryton_snipe_model_map.tryton_model_id` |
| `tryton_model_name` | Nombre de modelo en Tryton (auditoría) |
| `category_name` | Categoría derivada (auditoría) |

### `tryton_snipe_asset_map` — orquestador v2 (batch)

Mapa persistente Tryton ↔ Snipe-IT. Esquema en `public.tryton_snipe_asset_map` (BD `n8n`). **Fix 2026-08-28:** no existía; `Diff assets (batch)` y `Upsert asset map` fallaban. Añadida a `sql/init-sync-tables.sql` §6.

| Columna | Notas |
|---------|-------|
| `tryton_asset_id` | Clave (UNIQUE, target de `ON CONFLICT DO UPDATE`) |
| `tryton_code` | `code` de Tryton (mapeado a `snipe_asset_tag`) |
| `tryton_internal_code` | Código interno |
| `tryton_name` | Nombre en Tryton |
| `tryton_asset_state` | Estado Tryton |
| `tryton_model_id` | ID de modelo en Tryton |
| `snipe_asset_id` | ID del asset en Snipe-IT |
| `snipe_asset_tag` | `asset_tag` en Snipe-IT |
| `snipe_model_id` | FK a Snipe-IT `models.id` |
| `snipe_status_id` | FK a Snipe-IT `status_labels.id` |
| `snipe_name` | Nombre en Snipe-IT |
| `created_at`, `updated_at`, `last_synced_at` | Fechas (DEFAULT `now()`) |

### `staging_titular` — Tryton sync titular-activo (v1)

Tabla efímera por ejecución. `DELETE` al inicio y `INSERT` desde `jsonb_to_recordset`. Esquema en `public.staging_titular` (BD `n8n`). **Fix 2026-09-01:** no existía; `Reset/Cargar staging titular` fallaban con `relation "staging_titular" does not exist`. Añadida a `sql/init-sync-tables.sql` §8; `scripts/reset-sync.sh` actualizado.

| Columna | Notas |
|---------|-------|
| `snipe_asset_tag` | `asset_tag` en Snipe-IT |
| `email` | `login@guayas.gob.ec` |
| `first_name` | Title-cased |
| `last_name` | Title-cased |

### `snipe_titular_user_map` — cache email → snipe_user_id

Esquema en `public.snipe_titular_user_map` (BD `n8n`). **Fix 2026-09-01:** faltaba DDL §9.

| Columna | Notas |
|---------|-------|
| `email` | PK — `ON CONFLICT (email)` |
| `snipe_user_id` | ID en Snipe-IT |
| `updated_at` | `now()` |

### `snipe_titular_map` — titular vigente por activo

Esquema en `public.snipe_titular_map` (BD `n8n`). **Fix 2026-09-01:** faltaba DDL §10.

| Columna | Notas |
|---------|-------|
| `snipe_asset_tag` | PK — `ON CONFLICT (snipe_asset_tag)` |
| `email` | Email titular vigente |
| `snipe_user_id` | ID en Snipe-IT |
| `updated_at` | `now()` |

### `sync_run_summary` — orquestador v2 (batch)

Resumen por ejecución del orquestador. Esquema en `public.sync_run_summary` (BD `n8n`). **Fix 2026-08-28:** no existía; `Run summary` fallaba. Añadida a `sql/init-sync-tables.sql` §7.

| Columna | Notas |
|---------|-------|
| `id` | PK BIGSERIAL |
| `run_id` | `TEXT` — `$execution.id` (UNIQUE) |
| `total_tryton` | Total en staging |
| `to_create` / `to_update` | Conteo por acción |
| `unchanged` | `GREATEST(total - to_create - to_update - missing_model, 0)` |
| `missing_model` | Sin mapeo de modelo o estado |
| `deleted_in_tryton` | En `asset_map` pero no en staging |
| `api_errors` | `COUNT(*) FROM integration_sync_log WHERE execution_id = run_id` |
| `finished_at` | `now()` |

---

## 4.8 Limitaciones y errores conocidos

| Caso | Comportamiento actual |
|------|----------------------|
| Modelo sin mapeo | `snipe_model_id` undefined -> error JSON en `Create asset` |
| Nombre de modelo cambiado | PATCH automatico |
| Nombre duplicado en Snipe-IT | POST falla; el modelo queda sin mapeo |
| Modelo borrado en Snipe-IT | Falso "existe" por el mapa; sin reconciliacion |
| Categoria duplicada | **Self-heal:** busca en Snipe-IT por nombre y mapea si la encuentra |
| Categoria con comilla | `Search category` usa interpolacion directa SQL; puede romper |
| `asset_model` o `actual_value` nulos | `Flatten assets` lanza error |
| Mas de 100 activos | Sin paginacion; solo los primeros 100 |
| Rate limit Tryton/Snipe-IT | 429 posibles en operacion masiva |
| `SNIPE_HOST = localhost` dentro del stack | `ECONNREFUSED ::1:8080`; usar `http://snipe-it:80` |
| Pinned data en trigger de sub-workflow | `Unpin '<trigger>' to execute` al ejecutar desde orquestador |
| `onError: continueRegularOutput` en HTTP | Errores se capturan como `{error:{message,status}}` (con `fullResponse:true` sin `statusCode`/`body`) — no mapear `$json.statusCode` directamente |
| `Invalid key supplied` en Snipe-IT | Llaves Passport perdidas → bind `./snipe-data/snipeit:/var/lib/snipeit` + `chown apache:apache` |
| 401 `Unauthorized` en Snipe-IT | PAT de credencial `Bearer Auth account` (`httpBearerAuth` id `PipxV96bF9YxckC4`) inválido → regenerar en Snipe-IT y actualizar en n8n. > **Fix 2026-09-05:** 401 con PAT válido en `envs/n8n.env` (200 desde el host): la credencial guardaba un token corto obsoleto, el contenedor tenía `$SNIPEIT_TOKEN` viejo (`env_file` solo se lee al crear) y los snapshots usaban ids viejos. Fix: `export/import:credentials` con el token vigente + `docker compose up -d n8n` + sincronizar ids en los 5 snapshots (83 refs). Verificado `wget` interno → 200. |
| `$('Nodo').item` sobre nodo no ejecutado | Evalúa a vacío silenciosamente (ternario cruzado → `"\n  "`) |
| `staging_tryton_assets` / `tryton_snipe_asset_map` / `sync_run_summary` no existen en BD `n8n` | Orquestador v2 (batch) fallaba en `Reset staging` con `relation does not exist`; DDL faltaba en `sql/init-sync-tables.sql`. > **Fix 2026-08-28:** DDL añadido §5-7 a `sql/init-sync-tables.sql` y aplicado a BD `n8n`; spec § Tablas de mapeo y `scripts/reset-sync.sh` actualizados. |
| Merge `Wait models` `chooseBranch` dead-end | Orquestador v2: Merge recibía por input 1 y salía por output 1 no conectado → `Prepare staging payload` nunca recibía datos; `Prepare staging payload` leía `$('Wait models')` sin `result`. > **Fix 2026-08-28:** Merge eliminado; `Execute Tryton sync snipeIT models` → `Prepare staging payload` directo; payload migrado a `$('Flatten assets').first().json.result`. `Wait categories & statuses` pendiente (mismo patrón). |
| Sub-workflow models lanzado 1 vez por modelo | `Split Out models` + `Execute Workflow` modo `each`: 597 sub-ejecuciones seriales ≈ 331 s (~100% del run 288), queries PG por ítem, ~4.8 MB de `execution_data`/run. > **Fix 2026-08-28 (batch models):** lote en 1 item, modo once, `Resolve batch models` (1 query `jsonb_to_recordset`), filtro de no-ops en `Prepare items`, upsert bulk `ON CONFLICT (tryton_model_id)`; self-heal/log por-item; `saveDataSuccessExecution: none`. Steady-state: ~200-300 s → ~1-3 s. Ver §4.3. |
| `Prepare items` vaciaba salida en steady-state | `Prepare items` filtrado a 0 items dejaba al sub con 0 de salida → `Execute Workflow` sacaba 0 → `Prepare staging payload` no corría y la fase 2 quedaba muerta (run 886, 2026-08-31: staging/asset_map/summary vacíos). > **Fix 2026-08-31:** `Prepare items` emite item `noop` cuando no hay trabajo y `Has work?` lo rutea a `Finish`; el orquestador fija `alwaysOutputData: true` en `Execute models` como red. `Update snipe-it model` con `onError: continueRegularOutput`. |
| `$input.allItems is not a function` en `Build save payload` | Code `runOnceForAllItems` (`Build save payload`, `flows/flujos-dev/Tryton sync snipe-IT models.json:628`) usaba `$input.allItems()` — no existe en n8n (API es `$input.all()`/`$input.first()`/`$input.last()`). `TypeError` en `JsTaskRunner.runForAllItems` (n8n 2.36.7). > **Fix 2026-08-31:** `$input.all().map(i => i.json)`; re-importar workflow en n8n si se editó en la UI. |
| UI congelada al ejecutar nodo | `Search assets` sin límite (`0, null, null` → 9.5k filas, 7-10 MB `execution_entity.jsonSizeBytes`, runs 288/1053/1054) + `saveDataSuccessExecution: all` → navegador colgado al renderizar `Flatten assets`/`Prepare staging payload`/`Model list` y `JSON.stringify(rows)`. > **Fix 2026-08-31:** inicial `0,100,null` + `settings.saveDataSuccessExecution: none / …` en 6 workflows + `UPDATE workflow_entity`; `100` solo daba 23/558 modelos → restaurado a `0,null,null` para 558/597 manteniendo `saveDataSuccessExecution: none` + `Tag for save` a `Set` (vs `Code`) para no saturar task runner; limpiar `execution_entity` pesadas. |
| `Detectar cambios de titular` con 8000+ items congela UI / llena `execution_entity` | `Tryton sync titular-activo` (`yjyUYjVEaZ9UniSs`) sin `saveDataSuccessExecution: none` guardaba ~10 nodos × 8000 items (~10-30 MB/run); abrir la ejecución congelaba el navegador (mismo síntoma del fix 2026-08-31 para 6 workflows). > **Fix 2026-09-02:** `settings` alineados a `status`/`models`/`ingest` vía `UPDATE workflow_entity WHERE id='yjyUYjVEaZ9UniSs'` + `docker compose restart n8n`; snapshot sincronizado (ver §4.6). |
| 429 `Try spacing your requests out` en Snipe-IT models | `Create/Update snipe-it model` sin `batching` → `429` en `integration_sync_log` (150/582 run 1101; 219/291 con `5/1000`) por Snipe-IT rate limit. > **Fix 2026-08-31:** `options.batching.batch {batchSize:1, batchInterval:1200}` en ambos HTTP (`flows/flujos-dev/Tryton sync snipe-IT models.json:287,376`) + restart n8n; 558 modelos en ~670s sin 429. |
| `Find model in Snipe` `search=undefined` (self-heal roto) | `Find model in Snipe` usaba `$json.asset_model_name` tras `Create` con `fullResponse: true` → item es `{body,statusCode}` sin ese campo → `search=undefined` → `{"total":0}`; duplicados Tryton (mismo nombre ya sincronizado) nunca se recuperan → 40/597 sin mapeo (`tryton_snipe_model_map` 557/597). > **Fix 2026-09-01:** cambiado a `$('Prepare items').item.json.asset_model_name` en `flows/flujos-dev/Tryton sync snipe-IT models.json:476` + `UPDATE workflow_entity JODxuGjfCJ2wDobA` + backfill de 40 al `snipe_model_id` canónico; ver §4.3. |
| Custom field `_snipeit_internal_code_2` inexistente → 0 assets, `success` engañoso | `custom_fields` solo 1 fila (MAC, id 1) y `custom_fieldsets` solo id 1; faltaba `internal_code` (id 2 → `_snipeit_internal_code_2`) y fieldset id 2. Orquestador 1265/ingest 1266: 9565/8132/6314/0 en map/assets; todos los POST `/hardware` con `200 {"status":"error","messages":{"_snipeit_internal_code_2":[...]}}`. > **Fix 2026-09-01:** añadidos pre-flight `Check custom field internal_code` → `Has internal_code field?` → `Fail: missing custom field` (~1 s, `ejecute ./scripts/snipe-it_custom_fields.sh`) y post-loop `Has API errors?` → `Fail: ingest had API errors` (api_errors>0 → error); script `scripts/snipe-it_custom_fields.sh` idempotente + `docs/manual-implementacion.md`; re-export snapshot (21 nodos con Loop/Finish). |
| Activos huérfanos tras cancelación → 383 en Snipe-IT sin map | Cancelación a mitad de loop dejó 383 assets sin map (`Upsert` no llegó). Re-ejecución sin self-heal reintentaba `create` → `asset_tag must be unique` perpetuo. > **Fix 2026-09-01 (self-heal assets):** añadidos `Find asset in Snipe` (GET `/api/v1/hardware?asset_tag=X`, `=`) → `Recover asset` → `Recovered asset?` → `Upsert asset map` en rama `Saved? false`. Re-ejecución corrige los 383. Snapshot 21→24 nodos; sin duplicados de `code` verificado (0). |
| `Node execution failed` — task runner disconnect (OOM) | Ingest 9.5k payload + 24 nodos + self-heal excede heap del JS runner interno. Ejecuciones 1316/1317 abortan a ~6 min con `InternalTaskRunnerDisconnectAnalyzer`. > **Fix 2026-09-01:** `envs/n8n.env:5` `N8N_RUNNERS_MAX_OLD_SPACE_SIZE=4096` + `docker compose up -d n8n` (heap 4 GiB). Alternativa: `n8n-runner` externo (`N8N_RUNNERS_ENABLED=true`). Ver `docs/04` §4.5. |
| 429 `Try spacing your requests out` en Snipe-IT assets ingest | `Create/Update` sin batching → 429 en `access.log` (219 en 18:13-18:43, 112 faltantes sin log por `Log error` silencioso). > **Fix 2026-09-01:** `batchSize:1, batchInterval:550` + `retryOnFail 4×3s` en ambos HTTP + retry en `Find asset in Snipe`; `Recover` propaga `tryton_id` y `Log error` lee `$json.*`. Snapshot 24 nodos. |
| `Execute login` huérfano + `SNIPE_TOKEN` vs `SNIPEIT_TOKEN` + `TRYTON_HOST` vs `TRYTON_URL` en titular-activo | `Execute login` → `RuVLU1TOMoOxqVE3` (borrado) → falla primer nodo; `Aplicar` usaba `SNIPE_TOKEN` inexistente → 401 masivo (200/0/200×401); `Leer activos` usaba `TRYTON_HOST` vs `TRYTON_URL`. > **Fix 2026-09-01:** repuntado → `Cnq2yvzVCRTKFld5` y `TOKEN = $env.SNIPEIT_TOKEN \|\| $env.SNIPE_TOKEN` + `($env.TRYTON_URL \|\| $env.TRYTON_HOST)` + retry 3×3s y 2×1.5s/3s. Ver `flows/flujos-dev/Tryton sync users assets.json:45,89,228`. |
| `staging_titular`/`snipe_titular_map`/`snipe_titular_user_map` no existen en BD | Titular fallaba en `Reset/Cargar staging` con `relation does not exist`; DDL faltaba en `sql/init-sync-tables.sql` (solo §1-7). > **Fix 2026-09-01:** DDL §8-10 a `sql/init-sync-tables.sql` y aplicado; `scripts/reset-sync.sh` actualizado; `docs/04` §4.7 sincronizado. |
| Titular-activo tragaba errores (sin logging) | `Aplicar` solo a `staticData.lastRun` (no persistente; workflow en `success` con 0 aplicados). Sin `Log error` y omitidos invisibles. > **Fix 2026-09-01:** `status ok\|error` + IF `¿Aplicado?` → `Log error titular` (`titular_checkout`) + `Contar omitidos`/`Resumen/Log resumen` (`run_summary` titular). Snapshot 15→19 nodos. |
| No-revocación de titular | Solo asigna/reasigna; si `current_owner=null` el activo queda con titular anterior. > **Decisión 2026-09-01:** intencional por ahora (evita des-asignaciones masivas). Pendiente política de `checkin` automático. |
| `Task execution timed out after 300 seconds` en titular-activo | `Aplicar en Snipe-IT` (Code `runOnceForAllItems`, `flows/flujos-dev/Tryton sync users assets.json:228`) ejecutaba `ensureUser` + `checkout` en bucle `for...await` con `helpers.httpRequest` + `sleep(1500)` en una sola tarea del task runner (`N8N_RUNNERS_TASK_TIMEOUT=300`, n8n 2.36.7 `TaskBroker.handleTaskTimeout`). > **Fix 2026-09-02:** refactor a nodos nativos (`¿Usuario existente?` → `Buscar usuario` `GET /users?email=` → `¿Encontrado?` → `Preparar usuario nuevo` → `Crear usuario` `POST /users` → `Crear usuario (alt)` → `Antes de checkout` → `Checkout` `POST /hardware/{id}/checkout` → `Checkin` → `Checkout reintento`, todos `httpBearerAuth` `Adhjdtilu8D9eQs8`, `retryOnFail 3×2s`/`onError` nativos, `batching 20/500ms`); corre en proceso principal sin límite del runner. Snapshot 19→37 nodos. Ver §4.6. |
| `Buscar usuario por email` per-item colapsa Snipe-IT (50 min solo en ese nodo) | `Buscar usuario por email en Snipe-IT` (`GET /api/v1/users?email=&limit=1`, `batching 20/500ms`, `retryOnFail 3×2s`, `onError: continueErrorOutput`) con `Detectar cambios de titular` 8,991 items y `snipe_titular_user_map` vacío → 8,991 GETs, **96 éxito y 8,895 error** en ejecución 1487 (`timeout of 30000ms` 8,541, resto `ETIMEDOUT`/`ECONNRESET`/`EAI_AGAIN`), `executionTime` 2,991,056 ms (~50 min), Snipe-IT 804% CPU y DNS `EAI_AGAIN`; cada corrida repetía el costo (nunca llegaba a `Guardar usuario en mapa (BD)`). 74 usuarios en Snipe vs 698 emails distintos; `email=''` → primer usuario (falso match); 1 creación por *asset* (no por email) → ~13 intentos duplicados por email. > **Fix 2026-09-03:** precarga bulk antes del diff: `Precargar usuarios de Snipe-IT` (1 GET `/api/v1/users?limit=500`) → `Guardar mapa de usuarios (bulk)` (`jsonb_to_recordset($1) LOWER(email)`) → `Calcular usuarios faltantes` (`DISTINCT ON LOWER(email)` no en mapa) → `¿Hay usuarios faltantes?` → `Extraer usuarios faltantes` (1 por email) → `Crear usuario`/`Reintentar alt` → `Guardar usuario creado en mapa (BD)` + `Usuarios listos` (colapsa M→1); rama `false` directa a `Contar activos sin mapeo`. `Detectar cambios` con guarda `s.email<>''` y join `LOWER(s.email)`. `¿Titular ya mapeado en BD?` sin HTTP: `true`→`Usar usuario del mapa`, `false`→`Marcar usuario no disponible`→`Consolidar resultados`. Eliminados 3 nodos de búsqueda. Snapshot 37→45 nodos, `UPDATE workflow_entity yjyUYjVEaZ9UniSs` + `docker compose restart n8n`; spec y `docs/04` §4.6 sincronizados. | |
| `null value in column "snipe_user_id"` en `Save New User` (`andrea.sanchez@guayas.gob.ec`, `null`) | `Save New User` (`INSERT INTO snipe_titular_user_map(email, snipe_user_id) VALUES ($1,$2)`, `Tryton sync users assets.json:1495`, `snipe_user_id INTEGER NOT NULL`) fila `(andrea.sanchez@guayas.gob.ec, null, 2026-09-03 20:47:46)` (`3/9/2026 3:47:46 p. m.` `Postgres` `executeQuery` n8n `2.36.7`). `Tag New User`/`(Alt)` solo ` $json.body.payload.id`; si Snipe 200 `{"status":"error",...}` o `body.id`, `snipe_user_id` null y `INSERT` aborta rama. > **Fix 2026-09-03:** fallback `{{ $json.body?.payload?.id ?? $json.body?.id ?? $json.body?.data?.id ?? $json.payload?.id ?? $json.id }}` + IF `Has User ID?` (`snipe_user_id` isNotEmpty) true→`Save`, false→`Mark Missing ID` (`status error`) → `Users Ready` (fan-in 3→1, 46 nodos, `[8032,2176]`). Un email malo ya no tumba run; audit vía `Mark No User`→`Log Errors (bulk)`. Espejo de `.ai/specs/tryton-activos.md`. | |
| `ON CONFLICT DO UPDATE cannot affect row a second time` en `Bulk Save Users` (0 filas) | `Preload Snipe Users` `GET /api/v1/users?limit=500` devolvió 74 filas con 2 emails duplicados (`christian.calderon@guayas.gob.ec` snipe_ids 12/73 y `manuel.paez@guayas.gob.ec` 30/74, duplicados reales en Snipe-IT) → `Bulk Save Users` `INSERT ... SELECT ... ON CONFLICT (email) DO UPDATE` sin `DISTINCT ON` abortó (misma causa que el fix de `Package Results` pero en la precarga bulk). Statement atómico → 0 filas escritas, `user_map` en 0. > **Fix 2026-09-03:** `SELECT DISTINCT ON (LOWER(x.email)) LOWER(x.email), x.id, now() FROM jsonb_to_recordset($1) ... ORDER BY LOWER(x.email), x.id` (gana id menor, 12/30) en `Bulk Save Users` (`flows/flujos-dev/Tryton sync users assets.json`), `UPDATE workflow_entity yjyUYjVEaZ9UniSs` + `restart n8n`; dry-run `BEGIN; ... ROLLBACK;` verificó 72 inserts. |
| `Task execution timed out after 300 seconds` en `Users Ready` (titular-activo, n8n 2.36.7 `TaskBroker.handleTaskTimeout`) | `Users Ready` (`flows/flujos-dev/Tryton sync users assets.json:1403`, `Code` `const items=$input.all(); return [{json:{ok:true,n_usuarios_creados:items.length}}]`) trivial, pero su tarea espera al fan-out previo `Get Missing Users` → `Prep New User` → `Create Snipe User` / `Retry Alt Username` (cada `batchSize:20/batchInterval:500`, `timeout:30000`, `retryOnFail 3×2s`, `onError:continueErrorOutput`) → `Save New User`. Con ~698 emails y 8,991 assets el acumulado supera el default `N8N_RUNNERS_TASK_TIMEOUT=300` (aunque `settings.executionTimeout:3600`). > **Fix 2026-09-03:** `envs/n8n.env:6` `N8N_RUNNERS_TASK_TIMEOUT=3600` (igual que `executionTimeout:3600`; junto a `N8N_RUNNERS_MAX_OLD_SPACE_SIZE=4096` del Fix 2026-09-01) + `docker compose up -d n8n`. Verificar `docker compose config \| grep TASK_TIMEOUT` y `docker exec n8n env \| grep RUNNERS`. Alternativa externa: `n8n-runner` en `docker-compose.yml` (`N8N_RUNNERS_ENABLED=true`). Espejo de `.ai/specs/tryton-activos.md`. |
| UI perdida + máquina al límite tras titular-activo (execution_data 37 MB, host 11 Gi) | Ejecución 1497 (`yjyUYjVEaZ9UniSs` `success` `secs 2928` `jsonSizeBytes 37749545` data 35 MB + 1487 9 MB) guardó `execution_data.data` gigante pese a `settings.saveDataSuccessExecution:none` porque `saveManualExecutions:true` + `fullResponse:true` por 8000 checkouts y `Package Results.payload` 35 MB retienen todo. Navegador renderiza 35 MB → freeze; 197× `Task rejected Offer expired` + 14× `timeout exceeded when trying to connect` (pool PG agotado, `batchSize 20/500ms` 40 req/s). Host 11 Gi al límite. > **Fix 2026-09-03:** poda `DELETE FROM execution_data WHERE octet_length(data::text)>5MB` (62→36 MB, `VACUUM`, max 35→4.8 MB) y `EXECUTIONS_DATA_PRUNE=true` `MAX_AGE=168` `MAX_COUNT=500` `POOL_SIZE=5` en `envs/n8n.env`; throttling `Create/Retry`/`Checkout/Retry` `20→5` `500→1000` (5 req/s) en `Tryton sync users assets.json` + `docker compose up -d n8n`. Para audit sin UI: `SELECT id,status,EXTRACT(EPOCH FROM("stoppedAt"-"startedAt")) FROM execution_entity WHERE "workflowId"='yjyUYjVEaZ9UniSs' ORDER BY "startedAt" DESC;` y `SELECT COUNT(*) FROM snipe_titular_map` (129) vs `staging_titular` (8991). |
| `Use Mapped User` y `Prep Assignment` hacían lo mismo (doble Set en serie) | `Owner Mapped?` true → `Use Mapped User` (passthrough + rename) → `Prep Assignment` (passthrough puro) → `Checkout Asset`; 2× strip por item sin lógica extra. > **Fix 2026-09-04:** eliminado `Use Mapped User`, rename absorbido en `Prep Assignment`; 46→45 nodos, `UPDATE workflow_entity yjyUYjVEaZ9UniSs` sin restart. Espejo de `.ai/specs/tryton-activos.md`. |
| n8n segfault (exit 139) con tormenta Offer expired pese a throttling 1/1200 | 2026-09-04 19:11 UTC: n8n murió (SIGSEGV) tras racha `Task rejected by Runner`; ejecución 1510 (manual) quedó `crashed` sin efecto; 1508 (manual, 40min) en `error` con 17.6MB de `execution_data`. > **Fix 2026-09-04:** reiniciado (`docker compose up -d n8n`), 6 workflows activos; pendiente observar próxima corrida y revisar 1508 en UI. Espejo de `.ai/specs/tryton-activos.md`. |
| `Wrong type: '1052' is a number but was expecting a string` en `Has User ID?` + 429 checkout + literal `{{$json.email}}` + 4× `run_summary` | Ejecución 1508 (`error`, 2416s): `Has User ID?` (`number` `notEmpty`, `strict`) abortó en `Tag New User (Alt)` ante ID numérico → `Save New User` 0 runs, 226 emails sin crear → 1747 `Mark No User`; checkout parcial 1552+859 persistió. 4 HTTP con `batchSize: 5` sin intervalo → 954× `429` (cap 120/min). `Mark No User` literal sin `={{ }}` (1747 filas sin email). `Package Results` 1 vez por rama activa → 4 `run_summary`/ejecución (verdad = `SUM`/`MAX` por `execution_id`). > **Fix 2026-09-04:** `Has User ID?` + `Owner Mapped?` a `loose`; 4 HTTP a `1/1200` (~50/min); `Mark No User` a `={{ '...' + $json.email + ')' }}`. `UPDATE workflow_entity` + `restart n8n`; snapshot + spec sincronizados. |
| 224 falsos faltantes + preload limit=500 < 1160 + Create responde 200 status:error | Ejecución 1512 (`success` 751s, 5.6MB): 1739/1739 errores, 0 checkouts, 0 usuarios creados. Preload trajo 475/1160 → 224 POSTs a Snipe 200 `{status:error}` → `Tag` null → `Mark Missing ID`. Los 224 ya existían en `snipeit.users`. > **Fix 2026-09-04:** backfill 224 contra `snipeit.users` (dry-run → apply, 699 filas, 0 faltantes); `Preload Snipe Users` migrado a Code (paginado offset 0/500/1000); self-heal `Is Duplicate Error?` → `Find User in Snipe` → `Recover User` → `Save New User`. 47→50 nodos, `UPDATE workflow_entity yjyUYjVEaZ9UniSs` sin restart. Espejo de `.ai/specs/tryton-activos.md`. |
| `bad interpreter: /bin/bash^M` al ejecutar `scripts/snipe-it_custom_fields.sh` (Linux/macOS) | Archivo con CRLF en 244/244 líneas + `core.autocrlf=true`: el kernel busca `/bin/bash\r` y no existe. Además `#!/bin/bash` no es portable (macOS trae bash 3.2). > **Fix 2026-09-05:** convertido a LF, shebang a `#!/usr/bin/env bash` (`bash -n` OK, ejecución directa verificada en macOS); nuevo `.gitattributes` (`*.sh text eol=lf`) para que git no reintroduzca CRLF en futuros checkouts. Otros 5 scripts de `scripts/` siguen con CRLF (pendiente normalizar). > **Fix 2026-09-05 (token con `\r`):** `SNIPEIT_TOKEN` de `envs/n8n.env` (CRLF) metía `\r` en el header `Authorization` → Apache 400 HTML → `jq: parse error`. El script sanitiza token/URL y valida JSON con `require_json`; verificado end-to-end (field 2 + fieldset 2 asociados). Espejo de `.ai/specs/tryton-activos.md`. |
| `reset-sync.sh` obsoleto para reset total (contenedores `docker-*-1`, sin borrado de assets, `role "n8n_user\r"`) | > **Fix 2026-09-06:** defaults a `dbs-*`; paso 0 `DELETE FROM assets` (sin FKs, LAB ONLY); sanitize `\r` tras `source`; CRLF→LF. Reset total verificado (9518/544/28/7 → 0, cats=1/status=3) + backup en `/Volumes/CRGS-1T/Docker/backups-lab/reset-total-20260906/`. Espejo de `.ai/specs/tryton-activos.md`. |
| Contenedores evaden VPN (401/503 borde público) + backend exige `Host` sin puerto | > **Fix 2026-09-06:** forwarder TCP Mac `0.0.0.0:8443→10.100.2.229:443` (temporal, kill en FIN) + header `Host` estático en los 5 nodos Tryton + resume con `docker run --add-host … -e TRYTON_URL=https://<nombre>:8443 -e TRYTON_FULL_SYNC=true` (compose run v5.5 no acepta `--add-host`). Login verificado end-to-end. Espejo de `.ai/specs/tryton-activos.md`. |
| Full sync siempre trae ~9518 activos aunque no haya cambios | `Search assets` sin filtro + triple scan en memoria + `JSON.stringify(9518)`; cada run paga fetch completo. `write_date` es `timestamp` pero 95% NULL (nunca modificados). Riesgos: `deleted_in_tryton` falso con staging parcial; `Split Out` vacío cuelga el `Merge`. > **Fix 2026-09-06:** `Get last sync` (`MAX(finished_at)-2h`, NULL = full) + `Search assets`/`Read Owned Assets` con dominio `OR(write_date,create_date) >= since` (`TRYTON_FULL_SYNC=true` = full); `Has assets?` salta catálogos con 0 filas; `Run summary` cuenta `deleted` solo en full. Versionado (`INSERT history` + `versionId`) + re-export + restart. Verificado live: 7.5s vs 11676s, `total=0/errores=0`, 0 escrituras Snipe, mapas intactos. Operación: incremental diario + full semanal (§9.3 del manual). Espejo de `.ai/specs/tryton-activos.md`. |
| Throttle dispar + cuelgues sin timeout + pool PG saturado (optimización 1+2) | Models aún en `1/550ms` (tormenta 429: 1388s con retries); status/categories/`Checkin` sin batching/retry; 7 nodos sin `timeout`; pool PG 5; `execution_data` 12 runs >5MB (174MB); typo `SNIPEIT_TOKEN` en `envs/n8n.env`. Gotcha: `export:workflow` lee la versión de `workflow_history` (`versionId`), no la fila viva — hay que versionar (`INSERT history` + `versionId/activeVersionId`) además del `UPDATE`. > **Fix 2026-09-05:** todo Snipe a `1/1200ms` + retry + `timeout 30s` (Tryton 120s/60s); pool `5→10` (recrear n8n); índices `ix_sta_category_name`, `ix_tsam_model_id`, `ix_st_tryton_asset_id`; poda `>5MB` (174→25MB, `VACUUM FULL` 23→6.3MB); typo corregido; 6 workflows versionados + reinicio; snapshots re-sincronizados. Full inicial sigue `N×1.2s` por cap (9518≈3.2h). Espejo de `.ai/specs/tryton-activos.md`. |
| Snapshot stale + settings perdidos en titular-activo (objeto nuevo en n8n) | Snapshot commiteado era del objeto viejo `yjyUYjVEaZ9UniSs` y el vivo es `Yv8AlEkGEdwzRJrJ` (mismos 51 nombres, 0 node-IDs en común; +`Get last sync`, `Not Needs Checkin?`); orquestadores ya apuntaban al nuevo. Vivo con settings mínimos (sin endurecimiento 2026-09-02). > **Fix 2026-09-06:** settings re-aplicados vía `import:workflow` (diff = solo `settings`; reactivado, `active` True, sin restart); snapshot re-exportado + 3 stickies corregidos (gate `asset_map`/omitidos, preload paginado, checkin condicional); §4.6 al ID nuevo. Espejo de `.ai/specs/tryton-activos.md`. |
| Cap 120/min de Snipe-IT → 429s con n8n a 50/min | Límite por usuario/token (`api_throttle_per_minute`, default 120). > **Fix 2026-09-06:** `API_THROTTLE_PER_MINUTE=600` en `envs/snipe-it.env` + `config:cache` en caliente (header verificado 600, sin downtime). Pendiente: n8n a 1/300ms tras FIN de 506 → full ≈2h. Espejo de `.ai/specs/tryton-activos.md`. |
| Titular 0/8816: preload mudo + Tag sin body + Recover ''→crash | > **Fix 2026-09-06:** preload a `httpRequest`+Bearer env con retry; `body` preservado en Tags; Recover→`Has User ID?`; `Is Duplicate` loose. `user_map` 0→710 en ~2min. Espejo de `.ai/specs/tryton-activos.md`. |
| Muerte súbita CLI mid-titular (Mac 73MB libres, mapa bulk-at-end) | > **Fix 2026-09-06:** backfill `snipe_titular_map` desde Snipe (2289 certificados) → re-runs convergen; Zammad detenido; heap 2048; `caffeinate`. Espejo de `.ai/specs/tryton-activos.md`. |
