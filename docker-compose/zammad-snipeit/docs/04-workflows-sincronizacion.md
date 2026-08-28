# 4. Workflows de Sincronizacion Tryton -> Snipe-IT

Este documento describe los workflows de negocio que sincronizan datos de Tryton hacia Snipe-IT. Complementa `03-integracion-n8n-tryton.md` (autenticacion) y el spec `.ai/specs/tryton-activos.md`.

## Indice

- [4.1 Workflow principal: Tryton sync snipe-IT assets orchestrator v2](#41-workflow-principal-tryton-sync-snipe-it-assets-orchestrator-v2)
- [4.2 Tryton sync categories](#42-tryton-sync-categories)
- [4.3 Tryton sync snipe-IT models](#43-tryton-sync-snipe-it-models)
- [4.4 Tryton sync snipe-IT status](#44-tryton-sync-snipe-it-status)
- [4.5 Tablas de mapeo](#45-tablas-de-mapeo)
- [4.6 Limitaciones y errores conocidos](#46-limitaciones-y-errores-conocidos)

---

## 4.1 Workflow principal: Tryton sync snipe-IT assets orchestrator v2

**ID:** `3hh7DBsrq8A1rIQg`

### Ejecucion

- Trigger: **manual** (`When clicking 'Execute workflow'`). No es un webhook.
- **Fase 1 — catálogos:** login → categorías y estados en paralelo (`Execute Tryton sync snipe-IT categories` / `status`) → `Wait categories & statuses` → modelos (`Execute Tryton sync snipe-IT models`).
- **Fase 2 — batch PG (activos):** `Execute Tryton sync snipeIT models` → `Prepare staging payload` (`Code`, `const assets = $('Flatten assets').first().json.result`) → `Reset staging` → `Load staging (bulk)` → `Diff assets (batch)` → `Any changes?` → `Batch changes` (splitInBatches) → `Create snipe-IT asset (batch)` / `Update snipe-IT asset (batch)` → `Upsert asset map` / `Log error (batch)` → `Run summary`.

> **Estado:** experimental. Los workflows viejos en `flows/` fueron reemplazados por sub-workflows en `flows/flujos-dev/`.

> **Fix 2026-08-28 (PG-DDL):** los 6 nodos Postgres de la fase 2 (`Reset staging`, `Load staging (bulk)`, `Diff assets (batch)`, `Upsert asset map`, `Log error (batch)`, `Run summary`) apuntaban a `staging_tryton_assets`, `tryton_snipe_asset_map` y `sync_run_summary` que no existían en la BD `n8n`. Se añadió DDL §5-7 a `sql/init-sync-tables.sql` y se aplicó (ver §4.5).

> **Fix 2026-08-28 (Wait models):** Merge `Wait models` (`mode: chooseBranch`, input 1→output 1 no conectado → fase 2 nunca disparaba) eliminado; `Execute Tryton sync snipeIT models` conecta directo a `Prepare staging payload`; `Prepare staging payload` migrado de `$('Wait models')` a `$('Flatten assets')`. `Wait categories & statuses` queda pendiente (mismo patrón `chooseBranch`, sólo passthrough).

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
                                          Split Out models ──→ Execute models ──→ Prepare staging payload
                                                          |
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

### Fase 2 — Batch PG (staging/diff/upsert)

1. **Prepare staging payload** (Code): construye `payload = [{tryton_asset_id, code, internal_code, name, asset_state, tryton_model_id, tryton_model_name, category_name}, …]` desde los activos aplanados.
2. **Reset staging** (`n8n-nodes-base.postgres`, `DELETE FROM staging_tryton_assets;`).
3. **Load staging (bulk)** (`INSERT INTO staging_tryton_assets ... SELECT DISTINCT ON (tryton_asset_id) ... FROM jsonb_to_recordset($1) ON CONFLICT DO NOTHING RETURNING COUNT` — reemplazo `$1` = payload).
4. **Diff assets (batch)** (`SELECT ... FROM staging_tryton_assets s JOIN tryton_snipe_model_map m ON ... JOIN tryton_snipe_status_map st ON ... LEFT JOIN tryton_snipe_asset_map am ON ... WHERE IS DISTINCT` — calcula `action = 'create' | 'update'`).
5. **Any changes?** (IF sobre resultado de Diff).
6. **Batch changes** (`splitInBatches`, batch size 1) → **Create or update?** (IF `action`) → `POST /api/v1/hardware` / `PATCH /api/v1/hardware/{id}` con `asset_tag=code`, `model_id=snipe_model_id`, `status_id=snipe_status_id`.
7. **Saved?** (IF `body.status == "success"`) → **Upsert asset map** (`INSERT INTO tryton_snipe_asset_map ... ON CONFLICT (tryton_asset_id) DO UPDATE`) o **Log error (batch)** (`INSERT INTO integration_sync_log` con `execution_id=$execution.id`, `operation=action`, `response_status/response_body/error_message` del HTTP).
8. **Run summary** (`executeOnce`, `INSERT INTO sync_run_summary (run_id, total_tryton, to_create, to_update, unchanged, missing_model, deleted_in_tryton, api_errors) SELECT ... FROM staging ... LEFT JOIN ... RETURNING *`).

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

**Archivo:** `flows/flujos-dev/Tryton sync snipe-IT models.json` (ID `JODxuGjfCJ2wDobA`, inactivo) — invocado por el orquestador vía `Execute Tryton sync snipe-IT models`.

**Entrada:** `{ "model": "...", "category": "..." }` derivado del activo (`asset_model_name`, `asset_model_id`, `category`).

### Flujo

```
Tryton sync snipe-IT assets orchestrator ({asset_model_id, asset_model_name, category})
      ↓
Execute a SQL query (SELECT tryton_snipe_model_map WHERE tryton_model_id = $1) → Model exists?
  ├─ Sí → Not update? (tryton_name == asset_model_name)
  │        ├─ Sí → Finish
  │        └─ No → Update snipe-it model (PATCH /models/{id} {name, fieldset_id:2}) → Is SnipeIT Saved?
  └─ No → Search category (SELECT snipe_category_id FROM tryton_snipe_category_map WHERE tryton_name = $category)
              ↓
          Endpoint params → Create snipe-it model (POST /models {category_id, name, fieldset_id:2}) → Is SnipeIT Saved?
                         ↓
                    Is SnipeIT Saved? (body.status == "success")
                     ├─ Sí → Save SnipeIT Model (upsert) → Finish
                     └─ No → Find model in Snipe ─┐
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
  ├─ Sí → Save SnipeIT Model (upsert) → Finish
  └─ No → Log error → Finish
```

- `Find model in Snipe`: `onError: continueRegularOutput` — en 401/500 devuelve `{error:{message,status}}` en vez de fallar
- `Recover model`: busca el match exacto y, en `found:false`, **propaga contexto de error** (`response_status`, `error_message`, `response_body`, `operation`, `request_payload`) para que `Log error` lo registre completo
- `Log error` lee todo desde `$json.*` del output de `Recover model` (no referencia nodos no ejecutados)

> **Fix 2026-08-28:** `Log error` y `Recover model` tenían el mismo bug que `status` antes de su fix: `Log error` leía `$json.statusCode`/`$json.body.messages` sobre `{found:false}` y `operation` hardcodeado a `"create"` con `request_payload`/`response_body` que referenciaban `Create snipe-it model` directamente (vacío si la rama de `Update` ejecutó o si el error vino de `Find`/`Recover`). Fix: `Recover model` propaga `response_status`/`error_message`/`response_body`/`operation`/`request_payload` y `Log error` mapea `={{ $json.* }}`. Ver spec `.ai/specs/tryton-activos.md` § Tryton sync snipe-IT models.

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

## 4.5 Tablas de mapeo

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

## 4.6 Limitaciones y errores conocidos

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
