# 4. Workflows de Sincronizacion Tryton -> Snipe-IT

Este documento describe los workflows de negocio que sincronizan datos de Tryton hacia Snipe-IT. Complementa `03-integracion-n8n-tryton.md` (autenticacion) y el spec `.ai/specs/tryton-activos.md`.

## Indice

- [4.1 Workflow principal: Tryton sync snipe-IT assets orchestrator v2](#41-workflow-principal-tryton-sync-snipe-it-assets-orchestrator-v2)
- [4.2 Tryton sync categories](#42-tryton-sync-categories)
- [4.3 Tryton sync models (archivado)](#43-tryton-sync-models-archivado)
- [4.4 Tryton sync statuses (archivado)](#44-tryton-sync-statuses-archivado)
- [4.5 Tablas de mapeo](#45-tablas-de-mapeo)
- [4.6 Limitaciones y errores conocidos](#46-limitaciones-y-errores-conocidos)

---

## 4.1 Workflow principal: Tryton sync snipe-IT assets orchestrator v2

**ID:** `3hh7DBsrq8A1rIQg`

### Ejecucion

- Trigger: **manual** (`When clicking 'Execute workflow'`). No es un webhook.
- Orquesta: login -> categorias (sub-workflow) -> modelos y estados (batch inline).

> **Estado:** experimental. Los workflows viejos de models/statuses separados fueron eliminados; v2 los maneja en batch.

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

## 4.3 Tryton sync models (archivado)

> **Archivado:** el workflow viejo (`flows/Tryton sync models.json`, ID `Q5X3iqntFS1etrPW`) fue eliminado. Los modelos se manejan actualmente en batch dentro del orquestador v2.

---

## 4.4 Tryton sync statuses (archivado)

> **Archivado:** el workflow viejo (`flows/Tryton sync statuses.json`, ID `CisxFC1TxerOtZkG`) fue eliminado. Los estados se manejan actualmente en batch dentro del orquestador v2.

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

Auditoria de operaciones contra Snipe-IT. Limitaciones:

- `operation` hardcodeado a `create` (las actualizaciones quedan mal etiquetadas).
- Categorias/estados: `tryton_id` y `snipe_id` en `0`.
- `request_payload` parcial (solo el segundo bodyParameter).
- No hay mapa de activos ni reconciliacion de activos existentes.

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
| `onError: continueRegularOutput` en HTTP | Errores de conexion se capturan como item `[{"error": "..."}]` en vez de fallar |
