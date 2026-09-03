# 4. Workflows de Sincronizacion Tryton -> Snipe-IT

Este documento describe los workflows de negocio que sincronizan datos de Tryton hacia Snipe-IT. Complementa `03-integracion-n8n-tryton.md` (autenticacion) y el spec `.ai/specs/tryton-activos.md`.

## Indice

- [4.1 Workflow principal: Tryton sync snipe-IT assets orchestrator v2](#41-workflow-principal-tryton-sync-snipe-it-assets-orchestrator-v2)
- [4.2 Tryton sync categories](#42-tryton-sync-categories)
- [4.3 Tryton sync snipe-IT models](#43-tryton-sync-snipe-it-models)
- [4.4 Tryton sync snipe-IT status](#44-tryton-sync-snipe-it-status)
- [4.5 Tryton sync snipe-IT assets ingest (batch)](#45-tryton-sync-snipe-it-assets-ingest-batch)
- [4.6 Tablas de mapeo](#46-tablas-de-mapeo)
- [4.7 Limitaciones y errores conocidos](#47-limitaciones-y-errores-conocidos)

---

## 4.1 Workflow principal: Tryton sync snipe-IT assets orchestrator v2

**ID:** `3hh7DBsrq8A1rIQg`

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

## 4.5 Tryton sync snipe-IT assets ingest (batch)

**Archivo:** `flows/flujos-dev/Tryton sync snipe-IT assets ingest (batch).json` (ID `Asse2tIngestSub01`, inactivo) — invocado por el orquestador vía `Execute ingest (batch)` (`waitForSubWorkflow: true`).

**Trigger:** `Tryton sync snipe-IT assets orchestrator` (`n8n-nodes-base.executeWorkflowTrigger`, `inputSource: passthrough`).

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
               ├─ true  → Batch changes (splitInBatches, batch size 1)
               │              ↓ (done)           ↓ (each)
               │           Run summary        Create or update? (IF $json.action == 'create')
               │           (ver guarda        ├─ true  → Create snipe-IT asset (batch) (POST /api/v1/hardware {name, asset_tag, status_id, model_id, _snipeit_internal_code_2}, onError: continueRegularOutput, fullResponse: true)
               │            post-loop)       └─ false → Update snipe-IT asset (batch) (PATCH /api/v1/hardware/{snipe_asset_id} {name, asset_tag, status_id, model_id, _snipeit_internal_code_2}, onError: continueRegularOutput, fullResponse: true)
                │                                              ↓
                │                                           Saved? (IF body.status == "success")
                │                                            ├─ true  → Upsert asset map (INSERT INTO tryton_snipe_asset_map ...) → Loop → Batch changes
                │                                            └─ false → Find asset in Snipe (GET /api/v1/hardware?asset_tag={{code}}, fullResponse, onError: continueRegularOutput)
                │                                                         ↓
                │                                                      Recover asset (Code: match exacto en body.rows; encontrado → {found:true, payload}; no → propaga response_status/error del Create/Update)
                │                                                         ↓
                │                                                      Recovered asset? (IF $json.found)
                │                                                        ├─ true  → Upsert asset map → Loop → Batch changes
                │                                                        └─ false → Log error (batch) → Loop → Batch changes
                └─ false → Run summary (INSERT INTO sync_run_summary ...) → Has API errors? (IF ($json.api_errors ?? 0) > 0) → true: Fail: ingest had API errors / false: Finish
```

- `Check custom field internal_code` / `Has internal_code field?` / `Fail: missing custom field`: **pre-flight**. Verifica `GET /api/v1/fields` y que exista `db_column_name === '_snipeit_internal_code_2'` (id 2). Si falta, falla en ~1 s con mensaje accionable (`ejecute ./scripts/snipe-it_custom_fields.sh`) en vez de procesar 8k assets 50 min para que todos fallen con `_snipeit_internal_code_2 does not seem to exist`. Prerequisito: `scripts/snipe-it_custom_fields.sh` (idempotente) crea el custom field `internal_code` (text, ANY) → `_snipeit_internal_code_2`, el fieldset id 2 y los asocia. Ver `docs/manual-implementacion.md` §7.
- `Find asset in Snipe` / `Recover asset` / `Recovered asset?`: **self-heal assets** (replica patrón `Recover model`). Cuando `Create/Update` falla (p.ej. `asset_tag must be unique` por los 383 huérfanos), busca por `asset_tag` exacto (`GET /api/v1/hardware?asset_tag=X`, `=`) y si lo encuentra normaliza `body.payload` → `Upsert asset map` (`Recover` propaga `tryton_id`/`operation` y `Log error` lee `$json.*`). La re-ejecución corrige los huérfanos sin SQL manual.
- `Has API errors?` / `Fail: ingest had API errors`: **guarda post-loop**. Tras `Run summary`, si `api_errors > 0` el sub-workflow pasa a `error` (visible en n8n) en vez de `success` engañoso (caso 2026-09-01: `api_errors=6314/8132` pero ejecución en `success`). `Loop` es puente noOp hacia `Batch changes`; `Finish` es éxito. `Log error` lee `$json.*` propagado por `Recover` (no `$('Batch changes').item` cruzado) para evitar silencio por `continueRegularOutput`.
- `Create/Update snipe-IT asset (batch)`: `batchSize:1, batchInterval:550` + `retryOnFail (4×3s)` + `onError: continueRegularOutput` + `fullResponse` — evita `429` de Snipe-IT (throttle `api-throttle:api` 60/min) y reintenta. `Find asset in Snipe` también con retry 3×2s.
- `Upsert asset map` mapea `$('Batch changes').item.json.*` + `$json.body.payload.*`; `Log error` usa `$json.tryton_id`/`$json.operation`/`$json.response_status` de `Recover asset`.
- **Refactor 2026-08-28:** extraído del orquestador para mejorar mantenibilidad. `workflow_name` en `integration_sync_log` pasa a ser el nombre del sub-workflow (decisión acordada).

> **Fix 2026-09-01 (custom field internal_code faltante — 0 assets):** orquestador 1265 / ingest 1266 (`success` pero 0 assets). Fix: añadida guarda pre-flight y guarda post-loop + script `scripts/snipe-it_custom_fields.sh` idempotente; re-export snapshot (21 nodos con Loop/Finish).

> **Fix 2026-09-01 (self-heal assets — 383 huérfanos tras cancelación):** cancelación a mitad de loop dejó 383 assets en Snipe sin map (`Upsert` no llegó). Sin self-heal la re-ejecución reintentaba `create` → `asset_tag must be unique` perpetuo. Fix: añadidos `Find asset in Snipe` → `Recover asset` → `Recovered asset?` → `Upsert asset map` en rama `Saved? false`. Snapshot 21→24 nodos; sin duplicados de `code` en staging verificado (0).

---

## 4.6 Tablas de mapeo

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
- **General:** `tryton_id`/`snipe_id` en `0` para categorías/estados; sin mapa de activos ni reconciliación.

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

## 4.7 Limitaciones y errores conocidos

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
| 401 `Unauthorized` en Snipe-IT | PAT de credencial `Bearer Auth snipe-it` inválido → regenerar en Snipe-IT y actualizar en n8n |
| `$('Nodo').item` sobre nodo no ejecutado | Evalúa a vacío silenciosamente (ternario cruzado → `"\n  "`) |
| `staging_tryton_assets` / `tryton_snipe_asset_map` / `sync_run_summary` no existen en BD `n8n` | Orquestador v2 (batch) fallaba en `Reset staging` con `relation does not exist`; DDL faltaba en `sql/init-sync-tables.sql`. > **Fix 2026-08-28:** DDL añadido §5-7 a `sql/init-sync-tables.sql` y aplicado a BD `n8n`; spec § Tablas de mapeo y `scripts/reset-sync.sh` actualizados. |
| Merge `Wait models` `chooseBranch` dead-end | Orquestador v2: Merge recibía por input 1 y salía por output 1 no conectado → `Prepare staging payload` nunca recibía datos; `Prepare staging payload` leía `$('Wait models')` sin `result`. > **Fix 2026-08-28:** Merge eliminado; `Execute Tryton sync snipeIT models` → `Prepare staging payload` directo; payload migrado a `$('Flatten assets').first().json.result`. `Wait categories & statuses` pendiente (mismo patrón). |
| Sub-workflow models lanzado 1 vez por modelo | `Split Out models` + `Execute Workflow` modo `each`: 597 sub-ejecuciones seriales ≈ 331 s (~100% del run 288), queries PG por ítem, ~4.8 MB de `execution_data`/run. > **Fix 2026-08-28 (batch models):** lote en 1 item, modo once, `Resolve batch models` (1 query `jsonb_to_recordset`), filtro de no-ops en `Prepare items`, upsert bulk `ON CONFLICT (tryton_model_id)`; self-heal/log por-item; `saveDataSuccessExecution: none`. Steady-state: ~200-300 s → ~1-3 s. Ver §4.3. |
| `Prepare items` vaciaba salida en steady-state | `Prepare items` filtrado a 0 items dejaba al sub con 0 de salida → `Execute Workflow` sacaba 0 → `Prepare staging payload` no corría y la fase 2 quedaba muerta (run 886, 2026-08-31: staging/asset_map/summary vacíos). > **Fix 2026-08-31:** `Prepare items` emite item `noop` cuando no hay trabajo y `Has work?` lo rutea a `Finish`; el orquestador fija `alwaysOutputData: true` en `Execute models` como red. `Update snipe-it model` con `onError: continueRegularOutput`. |
| `$input.allItems is not a function` en `Build save payload` | Code `runOnceForAllItems` (`Build save payload`, `flows/flujos-dev/Tryton sync snipe-IT models.json:628`) usaba `$input.allItems()` — no existe en n8n (API es `$input.all()`/`$input.first()`/`$input.last()`). `TypeError` en `JsTaskRunner.runForAllItems` (n8n 2.36.7). > **Fix 2026-08-31:** `$input.all().map(i => i.json)`; re-importar workflow en n8n si se editó en la UI. |
| UI congelada al ejecutar nodo | `Search assets` sin límite (`0, null, null` → 9.5k filas, 7-10 MB `execution_entity.jsonSizeBytes`, runs 288/1053/1054) + `saveDataSuccessExecution: all` → navegador colgado al renderizar `Flatten assets`/`Prepare staging payload`/`Model list` y `JSON.stringify(rows)`. > **Fix 2026-08-31:** inicial `0,100,null` + `settings.saveDataSuccessExecution: none / …` en 6 workflows + `UPDATE workflow_entity`; `100` solo daba 23/558 modelos → restaurado a `0,null,null` para 558/597 manteniendo `saveDataSuccessExecution: none` + `Tag for save` a `Set` (vs `Code`) para no saturar task runner; limpiar `execution_entity` pesadas. |
| 429 `Try spacing your requests out` en Snipe-IT models | `Create/Update snipe-it model` sin `batching` → `429` en `integration_sync_log` (150/582 run 1101; 219/291 con `5/1000`) por Snipe-IT rate limit. > **Fix 2026-08-31:** `options.batching.batch {batchSize:1, batchInterval:1200}` en ambos HTTP (`flows/flujos-dev/Tryton sync snipe-IT models.json:287,376`) + restart n8n; 558 modelos en ~670s sin 429. |
| `Find model in Snipe` `search=undefined` (self-heal roto) | `Find model in Snipe` usaba `$json.asset_model_name` tras `Create` con `fullResponse: true` → item es `{body,statusCode}` sin ese campo → `search=undefined` → `{"total":0}`; duplicados Tryton (mismo nombre ya sincronizado) nunca se recuperan → 40/597 sin mapeo (`tryton_snipe_model_map` 557/597). > **Fix 2026-09-01:** cambiado a `$('Prepare items').item.json.asset_model_name` en `flows/flujos-dev/Tryton sync snipe-IT models.json:476` + `UPDATE workflow_entity JODxuGjfCJ2wDobA` + backfill de 40 al `snipe_model_id` canónico; ver §4.3. |
| Custom field `_snipeit_internal_code_2` inexistente → 0 assets, `success` engañoso | `custom_fields` solo 1 fila (MAC, id 1) y `custom_fieldsets` solo id 1; faltaba `internal_code` (id 2 → `_snipeit_internal_code_2`) y fieldset id 2. Orquestador 1265/ingest 1266: 9565/8132/6314/0 en map/assets; todos los POST `/hardware` con `200 {"status":"error","messages":{"_snipeit_internal_code_2":[...]}}`. > **Fix 2026-09-01:** añadidos pre-flight `Check custom field internal_code` → `Has internal_code field?` → `Fail: missing custom field` (~1 s, `ejecute ./scripts/snipe-it_custom_fields.sh`) y post-loop `Has API errors?` → `Fail: ingest had API errors` (api_errors>0 → error); script `scripts/snipe-it_custom_fields.sh` idempotente + `docs/manual-implementacion.md`; re-export snapshot (21 nodos con Loop/Finish). |
| Activos huérfanos tras cancelación → 383 en Snipe-IT sin map | Cancelación a mitad de loop dejó 383 assets sin map (`Upsert` no llegó). Re-ejecución sin self-heal reintentaba `create` → `asset_tag must be unique` perpetuo. > **Fix 2026-09-01 (self-heal assets):** añadidos `Find asset in Snipe` (GET `/api/v1/hardware?asset_tag=X`, `=`) → `Recover asset` → `Recovered asset?` → `Upsert asset map` en rama `Saved? false`. Re-ejecución corrige los 383. Snapshot 21→24 nodos; sin duplicados de `code` verificado (0). |
| `Node execution failed` — task runner disconnect (OOM) | Ingest 9.5k payload + 24 nodos + self-heal excede heap del JS runner interno. Ejecuciones 1316/1317 abortan a ~6 min con `InternalTaskRunnerDisconnectAnalyzer`. > **Fix 2026-09-01:** `envs/n8n.env:5` `N8N_RUNNERS_MAX_OLD_SPACE_SIZE=4096` + `docker compose up -d n8n` (heap 4 GiB). Alternativa: `n8n-runner` externo (`N8N_RUNNERS_ENABLED=true`). Ver `docs/04` §4.5. |
| 429 `Try spacing your requests out` en Snipe-IT assets ingest | `Create/Update` sin batching → 429 en `access.log` (219 en 18:13-18:43, 112 faltantes sin log por `Log error` silencioso). > **Fix 2026-09-01:** `batchSize:1, batchInterval:550` + `retryOnFail 4×3s` en ambos HTTP + retry en `Find asset in Snipe`; `Recover` propaga `tryton_id` y `Log error` lee `$json.*`. Snapshot 24 nodos. |
