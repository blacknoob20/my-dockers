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
- Orquesta: login → categorías, modelos y estados vía sub-workflows (`Execute Tryton sync snipe-IT categories` / `models` / `status`).

> **Estado:** experimental. Los workflows viejos en `flows/` fueron reemplazados por sub-workflows en `flows/flujos-dev/`.

### Diagrama (simplificado)

```
When clicking 'Execute workflow'
      |
Execute login (Tryton login)
      |
Search assets
      |
Flatten assets
      |
Category list -> Split Out categories -> Loop categories -> Execute Tryton sync categories
      |
Wait categories & statuses
      |
... (batch: modelos y estados inline)
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

### Enriquecimiento (`Endpoint assets params`)

Con `List all catalogs` (consulta a `tryton_snipe_model_map` y `tryton_snipe_status_map`) se construyen mapas:

```text
modelos: tryton_model_id -> snipe_model_id, snipe_category_id
status:  tryton_name     -> snipe_status_id
```

Cada activo recibe:

```text
snipe_category_id, snipe_model_id, snipe_status_id
```

### Creacion de activos (`Create asset`)

```json
POST /api/v1/hardware
{
  "name": "...",
  "asset_tag": "<code>",
  "status_id": 5,
  "model_id": 23
}
```

El body se construye por interpolacion cruda. Si `snipe_status_id` o `snipe_model_id` es `undefined`, n8n deja el campo vacio y el JSON no parsea (error `The value in the "JSON Body" field is not valid JSON`).

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
