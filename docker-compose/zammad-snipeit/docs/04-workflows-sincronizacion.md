# 4. Workflows de Sincronización Tryton → Snipe-IT

Este documento describe los workflows de negocio que sincronizan datos de Tryton hacia Snipe-IT. Complementa `03-integracion-n8n-tryton.md` (autenticación) y el spec `.ai/specs/tryton-activos.md`.

## Índice

- [4.1 Workflow principal: Tryton sync assets](#41-workflow-principal-tryton-sync-assets)
- [4.2 Tryton sync categories](#42-tryton-sync-categories)
- [4.3 Tryton sync models](#43-tryton-sync-models)
- [4.4 Tryton sync statuses](#44-tryton-sync-statuses)
- [4.5 Tablas de mapeo](#45-tablas-de-mapeo)
- [4.6 Limitaciones y errores conocidos](#46-limitaciones-y-errores-conocidos)

---

## 4.1 Workflow principal: Tryton sync assets

Archivo: `flows/Tryton sync assets.json` (ID `1k6JvwtUeXcHnAKe`)

### Ejecución

- Trigger: **manual** (`When clicking ‘Execute workflow’`). No es un webhook.
- Orquesta todos los sub-workflows: login, categorías, modelos, estados.

### Diagrama

```
When clicking ‘Execute workflow’
      ↓
Execute login (Tryton login)
      ↓
Search assets
      ↓
Flatten assets
      ↓
┌──────────────┬──────────────┬──────────────┐
│ Status list  │ Category list│ Model list   │
└──────┬───────┴──────┬───────┴──────┬───────┘
       ↓             ↓              ↓
  Loop statuses  Loop categories  Loop models
       ↓             ↓              ↓
  Tryton sync    Tryton sync     Tryton sync
  statuses       categories      models
       └─────────────┴──────┬───────┘
                            ↓
                    Wait categories & statuses
                            ↓
                        Model list
                            ↓
                    Loop Over models
                            ↓
                    Execute Tryton sync models
                            ↓
                        Wait models
                            ↓
                    List all catalogs
                            ↓
                    Endpoint assets params
                            ↓
                      Create asset
```

### Extracción de activos

`Search assets` usa `model.asset.search_read` con:

- Dominio: `asset_type_new in [6, 39, 40, 48, 61, 92]`
- Offset: `0`, Limit: `100`
- **No hay paginación**: solo se procesan los primeros 100 registros.

### Normalización (`Flatten assets`)

De cada registro se extrae:

```text
id, name, asset_state, code, internal_code,
actual_value (decimal), asset_model_id, asset_model_name,
current_owner_id, current_owner_name,
category, category_id, category_name
```

`category` se deriva del prefijo de `name` (texto antes de `:`), en mayúsculas. Si no hay `:`, se usa `NO DEFINIDO`.

### Enriquecimiento (`Endpoint assets params`)

Con `List all catalogs` (consulta a `tryton_snipe_model_map` y `tryton_snipe_status_map`) se construyen mapas:

```text
modelos: tryton_model_id → snipe_model_id, snipe_category_id
status:  tryton_name     → snipe_status_id
```

Cada activo recibe:

```text
snipe_category_id, snipe_model_id, snipe_status_id
```

### Creación de activos (`Create asset`)

```json
POST /api/v1/hardware
{
  "name": "...",
  "asset_tag": "<code>",
  "status_id": 5,
  "model_id": 23
}
```

El body se construye por interpolación cruda. Si `snipe_status_id` o `snipe_model_id` es `undefined`, n8n deja el campo vacío y el JSON no parsea (error `The value in the "JSON Body" field is not valid JSON`).

---

## 4.2 Tryton sync categories

Archivo: `flows/Tryton sync categories.json` (ID `6K1Olue3CsIyALJB`)

### Entrada

```json
{ "category": "COMPUTADORAS" }
```

(Usa `inputSource: passthrough`.)

### Flujo

```
Search category (tryton_snipe_category_map where tryton_name)
      ↓
Exists category?
 ├─ Sí → Finish
 └─ No → Create snipe-it category
            ↓
        Is SnipeIT Created? ($json.body.status == "success")
         ├─ Sí → Save SnipeIT Category (upsert)
         └─ No → Log error
```

### Detalles

- `POST /api/v1/categories` con `{ name, category_type: "asset" }`.
- `Full Response` activado: el IF usa `$json.body.status` y el upsert usa `$json.body.payload.*`.
- Upsert en `tryton_snipe_category_map`, matching por `tryton_name`.
- **Semántica:** `tryton_name` es el prefijo derivado del nombre del activo, no el ID de categoría de Tryton.

---

## 4.3 Tryton sync models

Archivo: `flows/Tryton sync models.json` (ID `Q5X3iqntFS1etrPW`)

### Entrada

```json
{
  "asset_model_id": 1519,
  "asset_model_name": "DDR3",
  "category": "COMPUTADORAS"
}
```

### Flujo (crear o actualizar)

```
Execute a SQL query (tryton_snipe_model_map where tryton_model_id)
      ↓
Model exists?
 ├─ No → Search category
 │         ↓
 │     Endpoint params
 │         ↓
 │     Create snipe-it model (POST /api/v1/models) [Full Response]
 │         ↓
 │     Is SnipeIT Saved?
 │      ├─ Sí → Save SnipeIT Category (upsert) → Finish
 │      └─ No → Log error → Finish
 └─ Sí → Not update?
          ├─ Sí (nombres iguales) → Finish
          └─ No (nombre cambió) → Update snipe-it model (PATCH /api/v1/models/:id) [Full Response]
                    ↓
                Is SnipeIT Saved?
                 ├─ Sí → Save SnipeIT Category (upsert) → Finish
                 └─ No → Log error → Finish
```

### Claves técnicas

- `Create` y `Update` devuelven el mismo formato gracias a `Full Response`:

```json
{
  "body": {
    "status": "success",
    "payload": { "id": 23, "name": "DDR3 8GB", "category": { "id": 12 } }
  },
  "headers": {}
}
```

- El IF común `Is SnipeIT Saved?` evalúa `$json.body.status == "success"`.
- El upsert toma `tryton_model_id` y `tryton_name` desde `$('When Executed by Tryton sync assets').item.json` porque ese trigger **siempre** se ejecuta; `Endpoint params` solo corre en la rama de creación.

### Cambios de nombre

Cuando el nombre del modelo cambia en Tryton:

```text
tryton_name (mapa) = "DDR3"
asset_model_name (actual) = "DDR3 8GB"
```

Se ejecuta:

```json
PATCH /api/v1/models/13
{
  "name": "DDR3 8GB"
}
```

Los activos existentes conservan `snipe_model_id = 13`; solo cambia el nombre mostrado.

---

## 4.4 Tryton sync statuses

Archivo: `flows/Tryton sync statuses.json` (ID `CisxFC1TxerOtZkG`)

### Entrada

```json
{ "status": "good" }
```

(Usa `inputSource: passthrough`.)

### Flujo

```
Execute login (Tryton login)
      ↓
Tryton status catalog (model.asset.fields_get [asset_state])
      ↓
Tryton status list (selection → [{name, label}])
      ↓
Status list (Code: mapea tipo Snipe-IT)
      ↓
Search status (tryton_snipe_status_map where tryton_name)
      ↓
Status exists?
 ├─ Sí → Finish
 └─ No → Create snipe-it status (POST /api/v1/statuslabels) [Full Response]
            ↓
        Is SnipeIT Created?
         ├─ Sí → Save SnipeIT Status (upsert)
         └─ No → Log error
```

### Mapeo estado → tipo

| Estado Tryton | Tipo Snipe-IT |
|---------------|---------------|
| `good` | `deployable` |
| `regular` | `deployable` |
| `bad` | `pending` |
| `seized` | `pending` |
| `repair` | `pending` |
| `disuse` | `pending` |
| `unspecified` | `pending` |
| `baja` | `archived` |

Estados desconocidos: `label: "Sin mapear: <estado>"`, `type: pending`, `unknown: true`.

### Nombre del status label

```
{{ `${status}: ${label}` }}
```

Ejemplo: `good: Bueno`.

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
| `snipe_category_id` | ID de categoría Snipe-IT |
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

Auditoría de operaciones contra Snipe-IT. Limitaciones:

- `operation` hardcodeado a `create` (las actualizaciones quedan mal etiquetadas).
- Categorías/estados: `tryton_id` y `snipe_id` en `0`.
- `request_payload` parcial (solo el segundo bodyParameter).
- No hay mapa de activos ni reconciliación de activos existentes.

---

## 4.6 Limitaciones y errores conocidos

| Caso | Comportamiento actual |
|------|----------------------|
| Modelo sin mapeo | `snipe_model_id` undefined → error JSON en `Create asset` |
| Nombre de modelo cambiado | PATCH automático |
| Nombre duplicado en Snipe-IT | POST falla; el modelo queda sin mapeo |
| Modelo borrado en Snipe-IT | Falso "existe" por el mapa; sin reconciliación |
| Categoría duplicada | POST falla; no queda mapeada |
| Categoría con comilla | `Search category` usa interpolación directa SQL; puede romper |
| `asset_model` o `actual_value` nulos | `Flatten assets` lanza error |
| Más de 100 activos | Sin paginación; solo los primeros 100 |
| Rate limit Tryton/Snipe-IT | 429 posibles en operación masiva |
