# Spec: Integración Tryton → Snipe-IT

## Contexto

Este spec documenta la integración completa entre el ERP Tryton y Snipe-IT vía n8n. La integración extrae activos de informática de Tryton y los sincroniza en Snipe-IT, mapeando categorías, modelos y estados.

---

## Arquitectura

La integración se compone de un **sub-workflow de autenticación** y **workflows de negocio**:

| Workflow | Tipo | Archivo | ID |
|----------|------|---------|-----|
| **Tryton login** | Sub-workflow (autenticación) | `flows/tryton/Tryton login.json` | `lwtmczcb4xwWrwvN` |
| Tryton sync categories | Workflow de negocio | `flows/Tryton sync categories.json` | `6K1Olue3CsIyALJB` |
| Tryton sync models | Workflow de negocio | `flows/Tryton sync models.json` | `Q5X3iqntFS1etrPW` |
| Tryton sync statuses | Workflow de negocio | `flows/Tryton sync statuses.json` | `CisxFC1TxerOtZkG` |
| Tryton sync assets | Workflow principal (orquestador) | `flows/Tryton sync assets.json` | `1k6JvwtUeXcHnAKe` |

> **Nota:** los archivos en `flows/` son snapshots de n8n. Al modificar un workflow en la UI, re-exportarlo para mantenerlos al día.

---

## Sub-workflow: Tryton login

Archivo: `flows/tryton/Tryton login.json`

### Propósito

Sub-workflow de autenticación reutilizable. Se ejecuta desde otros workflows vía `Execute Workflow`. Cachea la sesión en `staticData` global, la valida con `get_preferences`, y hace re-login si expiró.

### Diagrama

```
Executed by Tryton Sync Assets
      ↓
Read session (staticData.tryton)
      ↓
Some session? (IF)
  ├── SÍ ──→ Testing session (get_preferences)
  │              ↓
  │         Is working? (IF)
  │          ├── SÍ ──→ Edit Fields ──→ Finish
  │          └── NO ──→ Tryton login (POST common.db.login)
  └── NO ──→ Tryton login (POST common.db.login)
                 ↓
            Is success? (IF: error array length === 0)
              ├── SÍ → Save Authentication ──→ Edit Fields ──→ Finish
              └── NO → Some session? (reintento sin contador)
```

Ruta de error de transporte (HTTP/red):

```
Tryton login (error de red)
      ↓
Retries 3 times (Code: contador en staticData, máx 3)
      ↓
Is not alive? (IF)
  ├── SÍ → Mail notif (POST ws.guayas.gob.ec/public/mail)
  │            ↓
  │        Stop and Error
  └── NO → Tryton login (reintento)
```

### Nodos clave

| Nodo | Tipo | Función |
|------|------|---------|
| `Read session` | Code | Lee `$getWorkflowStaticData('global').tryton` |
| `Some session?` | IF | `$json.some_session === true` |
| `Testing session` | HTTP Request | `model.res.user.get_preferences(false, {})` con Auth header |
| `Is working?` | IF | `$json.error` vacío? |
| `Tryton login` | HTTP Request | `POST common.db.login` con `$env.TRYTON_USER`/`$env.TRYTON_PASS` |
| `Is success?` | IF | `($json.error \|\| []).length === 0` |
| `Save Authentication` | Code | Construye `Session <base64(user:uid:session)>` y guarda en staticData |
| `Edit Fields` | Set | Output: `{ authorization }` |
| `Retries 3 times` | Code | Contador de reintentos (máx 3) en staticData |
| `Is not alive?` | IF | `$json.shouldStop === true` |
| `Mail notif` | HTTP Request | POST a `https://ws.guayas.gob.ec/public/mail` (multipart-form-data) |
| `Stop and Error` | Stop and Error | Termina con error |

### Output

```json
{
  "authorization": "Session c3ZjX244bjoyMTYwOjgxZmNiMDVl..."
}
```

### Variables de entorno requeridas

| Variable | Descripción |
|----------|-------------|
| `TRYTON_URL` | URL del servidor Tryton |
| `TRYTON_DB` | Nombre de la base de datos |
| `TRYTON_USER` | Usuario de servicio |
| `TRYTON_PASS` | Contraseña |
| `MAIL_FROM`, `MAIL_FROM_NAME` | Remitente de notificaciones |
| `MAIL_TO`, `MAIL_TO_NAME` | Destinatario de notificaciones |
| `MAIL_BODY` | Cuerpo del email de error |
| `MAIL_TOKEN` | Token del servicio de correo |

> **Requisito:** `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` en `n8n.env` para acceso a `$env.` dentro de nodos.

### Comportamiento de errores

| Situación | Comportamiento |
|-----------|---------------|
| Sesión cacheada vigente | Se reusa sin hacer login |
| Sesión expirada | Re-login automático (1 request adicional) |
| Error JSON-RPC (HTTP 200 con `error` en body) | Vuelve a `Some session?` y reintenta **sin** pasar por el contador |
| Error de transporte HTTP (red caída) | Pasa por `Retries 3 times` |
| 3 reintentos fallidos | Alerta por correo y `Stop and Error` |

### Código clave

**Save Authentication:**
```javascript
const [uid, session] = $json.result;
const auth = Buffer
  .from(`${$env.TRYTON_USER}:${uid}:${session}`)
  .toString('base64');

const staticData = $getWorkflowStaticData('global');
staticData.tryton = { uid, session, authorization: `Session ${auth}` };
return staticData.tryton;
```

**Read session:**
```javascript
const staticData = $getWorkflowStaticData('global');
if (!staticData.tryton) return { some_session: false };
return { some_session: true, ...staticData.tryton };
```

**Retries 3 times:**
```javascript
const staticData = $getWorkflowStaticData('global');
const MAX_RETRIES = 3;

if (staticData.retryCount >= MAX_RETRIES) {
  staticData.retryCount = 0;
  staticData.sessionHash = null;
  staticData.tryton = null;
  return { json: { shouldStop: true, reason: "Max retries reached" } };
}

staticData.retryCount = (staticData.retryCount || 0) + 1;
return { json: { shouldStop: false, retryCount: staticData.retryCount } };
```

---

## Servidores Tryton

| Entorno | URL | Base de datos |
|---------|-----|---------------|
| Laboratorio | `http://192.168.56.102:8000` | `dbegoblocal` |
| Producción | `https://financieroprueba.guayas.gob.ec` | `dbegob2bak` |

**Rate limit producción:** agresivo (429). Respetar mínimo 3 segundos entre requests.

---

## Protocolo JSON-RPC

```
POST /<database>/
Content-Type: application/json
Authorization: Session <base64(user:uid:session)>

{
  "id": 0,
  "method": "<method>",
  "params": [...]
}
```

---

## Workflows de sincronización

### Tryton sync assets (orquestador)

- **Trigger:** manual
- **Orquesta:** login → categorías → estados → modelos → activos
- **Extracción:** `model.asset.search_read` con dominio `asset_type_new in [6, 39, 40, 48, 61, 92]`, límite 100 registros (sin paginación)
- **Enriquecimiento:** cruzar con `tryton_snipe_model_map` y `tryton_snipe_status_map` para obtener IDs de Snipe-IT
- **Creación:** `POST /api/v1/hardware`

### Tryton sync categories

- **Entrada:** `{ "category": "COMPUTADORAS" }` (prefijo derivado del nombre del activo)
- **Flujo:** buscar en `tryton_snipe_category_map` → si no existe, crear en Snipe-IT (`POST /api/v1/categories`) → upsert en tabla de mapeo

### Tryton sync models

- **Entrada:** `{ "asset_model_id", "asset_model_name", "category" }`
- **Flujo:** buscar en `tryton_snipe_model_map` → si no existe, crear en Snipe-IT (`POST /api/v1/models`) → si existe y el nombre cambió, actualizar (`PATCH /api/v1/models/:id`) → upsert en tabla de mapeo

### Tryton sync statuses

- **Entrada:** `{ "status": "good" }`
- **Flujo:** obtener catálogo de estados vía `model.asset.fields_get` → mapear tipo Snipe-IT → buscar en `tryton_snipe_status_map` → si no existe, crear en Snipe-IT (`POST /api/v1/statuslabels`) → upsert en tabla de mapeo

---

## Tablas de mapeo (PostgreSQL — BD de n8n)

### `tryton_snipe_category_map`

| Columna | Notas |
|---------|-------|
| `tryton_name` | Clave (prefijo derivado del nombre del activo) |
| `snipe_category_id` | ID en Snipe-IT |
| `snipe_name` | Nombre en Snipe-IT |

### `tryton_snipe_model_map`

| Columna | Notas |
|---------|-------|
| `tryton_model_id` | Clave |
| `tryton_name` | Nombre en Tryton (se actualiza) |
| `snipe_model_id` | ID en Snipe-IT |
| `snipe_category_id` | ID de categoría Snipe-IT |

### `tryton_snipe_status_map`

| Columna | Notas |
|---------|-------|
| `tryton_name` | Clave (estado Tryton) |
| `snipe_status_id` | ID del status label |
| `snipe_name` | Nombre en Snipe-IT |
| `status_type` | `deployable`, `pending`, `archived` |

### Mapeo estado Tryton → tipo Snipe-IT

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

### `integration_sync_log`

Auditoría de operaciones contra Snipe-IT. Limitaciones conocidas:
- `operation` hardcodeado a `create`
- Categorías/estados: `tryton_id` y `snipe_id` en `0`
- `request_payload` parcial
- Sin reconciliación de activos existentes

---

## Errores conocidos

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
