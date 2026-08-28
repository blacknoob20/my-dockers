# Spec: Integración Tryton → Snipe-IT

## Contexto

Este spec documenta la integración completa entre el ERP Tryton y Snipe-IT vía n8n. La integración extrae activos de informática de Tryton y los sincroniza en Snipe-IT, mapeando categorías, modelos y estados.

---

## Arquitectura

La integración se compone de un **sub-workflow de autenticación** y **workflows de negocio**:

| Workflow | Tipo | Archivo | ID |
|----------|------|---------|-----|
| **Tryton login** | Sub-workflow (autenticación) | `flows/tryton/Tryton login.json` | `Cnq2yvzVCRTKFld5` |
| **Tryton login-gmail** | Sub-workflow (autenticación, variante) | — | `HJXnroz6Yno7mkIg` |
| Tryton sync categories | Sub-workflow de negocio | `flows/flujos-dev/Tryton sync snipe-IT categories.json` | `Ps2wicy3xI4n37nD` |
| Tryton sync snipe-IT models | Sub-workflow de negocio | `flows/flujos-dev/Tryton sync snipe-IT models.json` | `JODxuGjfCJ2wDobA` |
| Tryton sync snipe-IT status | Sub-workflow de negocio | `flows/flujos-dev/Tryton sync snipe-IT status.json` | `DFYH9aXY2QE6uJzl` |
| Tryton sync snipe-IT assets orchestrator v2 | Orquestador (batch) | — | `3hh7DBsrq8A1rIQg` |

> **Nota:** los archivos en `flows/` son snapshots de n8n. Al modificar un workflow en la UI, re-exportarlo para mantenerlos al día.

> **Archivos eliminados:** `flows/Tryton sync assets.json`, `flows/Tryton sync categories.json`, `flows/Tryton sync models.json`, `flows/Tryton sync snipe-IT assets orchestrator.json`, `flows/Tryton sync snipe-IT models.json`, `flows/Tryton sync snipe-IT status.json` — todos con IDs muertos (workflows reemplazados o eliminados en la instancia live).

---

## Sub-workflow: Tryton login

Archivo: `flows/tryton/Tryton login.json` (ID `Cnq2yvzVCRTKFld5`)

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
              ├── SÍ → Save Authentication ──→ Finish (directo, token fresco)
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
| `Save Authentication` | Code | Construye `Session <base64(user:uid:session)>`, guarda en staticData y devuelve el token fresco directo a `Finish` |
| `Edit Fields` | Set | Solo en el path de sesión cacheada vigente; output `{ authorization }` tomado de `Read session` |
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
| `SNIPE_HOST` | URL de Snipe-IT **dentro de la red Docker** (ver nota abajo) |
| `SNIPEIT_TOKEN` | Token API de Snipe-IT (usado por la credencial `Bearer Auth snipe-it` / `httpBearerAuth` id `Adhjdtilu8D9eQs8`) |
| `MAIL_FROM`, `MAIL_FROM_NAME` | Remitente de notificaciones |
| `MAIL_TO`, `MAIL_TO_NAME` | Destinatario de notificaciones |
| `MAIL_BODY` | Cuerpo del email de error |
| `MAIL_TOKEN` | Token del servicio de correo |

> **Requisito:** `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` en `n8n.env` para acceso a `$env.` dentro de nodos.

> **Gotcha `SNIPE_HOST`:** dentro del contenedor n8n, `localhost` se resuelve a `::1` (IPv6) y Snipe-IT no escucha ahí → `ECONNREFUSED ::1:8080`. Usar siempre el nombre del servicio Docker: `http://snipe-it:80` (en la red `net` del compose). **No** usar `http://localhost:8080` (eso funciona solo desde el host, no desde dentro del stack).

> **Fix 2026-08-27:** `SNIPE_HOST` estaba como `http://localhost:8080` en `envs/n8n.env`. Los nodos HTTP de Snipe-IT fallaban con `ECONNREFUSED ::1:8080` silenciosamente (via `onError: continueRegularOutput`). Fix: cambiar a `http://snipe-it:80` + recrear contenedor n8n.

### Comportamiento de errores

| Situación | Comportamiento |
|-----------|---------------|
| Sesión cacheada vigente | Se reusa sin hacer login |
| Sesión expirada | Re-login automático (1 request adicional); el token fresco de `Save Authentication` va directo a `Finish` (nunca se devuelve la sesión vencida del cache) |
| Error JSON-RPC (HTTP 200 con `error` en body) | Vuelve a `Some session?` y reintenta **sin** pasar por el contador |
| Error de transporte HTTP (red caída) | Pasa por `Retries 3 times` |
| 3 reintentos fallidos | Alerta por correo y `Stop and Error` |

> **Fix 2026-08-27:** `Edit Fields` usaba `||` (`Read session.authorization || Save Authentication.authorization`). Cuando la sesión cacheada estaba vencida, el re-login creaba un token nuevo en `Save Authentication`, pero `||` devolvía el valor truthy y vencido de `Read session`. Resultado: `Search assets` recibía un token expirado → **401**. Fix: `Save Authentication` conecta directo a `Finish`; `Edit Fields` solo se usa en el path de sesión-cacheada-válida.

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

### Tryton sync snipe-IT assets orchestrator v2 (batch)

- **Trigger:** manual (`When clicking 'Execute workflow'`)
- **Orquesta:** `Execute login` → `Search assets` → `Flatten assets` → `Category list`/`Model list`/`Status list` → `Split Out` por entidad → `Execute Tryton sync snipe-IT categories` / `Execute Tryton sync snipe-IT models` / `Execute Tryton sync snipe-IT status` (sub-workflows vía `Execute Workflow`)
- **ID:** `3hh7DBsrq8A1rIQg` — inactivo, se dispara manualmente
- **Nota:** los workflows viejos `flows/Tryton sync snipe-IT models.json` y `flows/Tryton sync snipe-IT status.json` (IDs muertos) fueron reemplazados por los sub-workflows en `flows/flujos-dev/` listados arriba

### Tryton sync categories

- **Archivo:** `flows/flujos-dev/Tryton sync snipe-IT categories.json` (ID `Ps2wicy3xI4n37nD`)
- **Trigger:** Execute Workflow Trigger (renombrado `Tryton sync snipe-IT assets orchestrator`)
- **Entrada:** `{ "category": "COMPUTADORAS" }` (prefijo derivado del nombre del activo)
- **Flujo:** buscar en `tryton_snipe_category_map` → si no existe, crear en Snipe-IT → auto-recuperación si la creación falla (ver Self-heal abajo)
- **URL Snipe-IT:** usa `$env.SNIPE_HOST` (no hardcodeado)

#### Self-heal: auto-recuperación de categorías duplicadas

Cuando la creación falla (ej: nombre duplicado → HTTP 422), el flujo no termina en error. En vez de eso, busca la categoría existente en Snipe-IT por nombre y la mapea:

```
Is SnipeIT Created? ($json.body.status == "success")
 ├─ Sí → Save SnipeIT Category (upsert) → Finish
 └─ No → Find category in Snipe (GET /api/v1/categories?search=<name>)
                ↓
          Recover category (Code: normaliza respuesta)
                ↓
          Recovered category? ($json.found == true)
           ├─ Sí → Save SnipeIT Category (upsert) → Finish
           └─ No → Log error → Finish
```

- `Find category in Snipe`: HTTP Request con `onError: continueRegularOutput` (si falla, devuelve `{ found: false }`)
- `Recover category`: Code node que busca el match exacto por nombre (case-insensitive) y construye el mismo formato de payload que la creación exitosa
- `onError: continueRegularOutput` en `Find category in Snipe` significa que errores de conexión se capturan como item `[{"error": "..."}]` en vez de marcar el nodo en rojo

### Tryton sync snipe-IT models

- **Archivo:** `flows/flujos-dev/Tryton sync snipe-IT models.json` (ID `JODxuGjfCJ2wDobA`, inactivo)
- **Trigger:** Execute Workflow Trigger (`Tryton sync snipe-IT assets orchestrator`)
- **Entrada:** `{ "model": "...", "category": "..." }` derivado del activo
- **Invocado por:** orquestador v2 vía `Execute Tryton sync snipe-IT models`

### Tryton sync snipe-IT status

- **Archivo:** `flows/flujos-dev/Tryton sync snipe-IT status.json` (ID `DFYH9aXY2QE6uJzl`, activo)
- **Trigger:** Execute Workflow Trigger (`Tryton sync snipe-IT assets orchestrator`, `inputSource: passthrough`)
- **Entrada:** `{ "status": "good" }` (estado Tryton asignado al activo)
- **Invocado por:** orquestador v2 vía `Execute Tryton sync snipeIT status` (uno por estado)

#### Flujo

```
Tryton sync snipe-IT assets orchestrator ({status})
      ↓
Execute login → Tryton status catalog (model.asset.fields_get asset_state)
      ↓
Tryton status list → Status asset (Code: knownTypes → type/label/desired_name)
      ↓
Search status (SELECT tryton_snipe_status_map WHERE tryton_name = $1)
      ↓
Status exists? (tryton_name notEmpty)
 ├─ Sí → Status up to date? (snipe_name == desired_name && status_type == type)
 │        ├─ Sí → Finish
 │        └─ No → Update snipe-it status (PATCH /statuslabels/{id} {name, type})
 │                     ↓
 │                Is SnipeIT Saved? (body.status == "success")
 │                 ├─ Sí → Save SnipeIT Status (upsert tryton_snipe_status_map)
 │                 └─ No → Find status in Snipe ─┐
 └─ No → Create snipe-it status (POST /statuslabels {name, type}) ─┘
                        ↓
                   Is SnipeIT Saved? ─────────────┘
```

#### Self-heal: auto-recuperación de estados duplicados

```
Is SnipeIT Saved? == false
      ↓
Find status in Snipe (GET /api/v1/statuslabels?search=<desired_name>, onError: continueRegularOutput, fullResponse: true)
      ↓
Recover status (Code: match exacto case-insensitive por name)
      ↓
Recovered status? (found == true)
 ├─ Sí → Save SnipeIT Status (upsert) → Finish
 └─ No → Log error → Finish
```

- `Find status in Snipe`: `onError: continueRegularOutput` — en 401/500 devuelve `{error:{message,status}}` en vez de fallar
- `Recover status`: busca el match exacto y, en `found:false`, **propaga contexto de error** (`response_status`, `error_message`, `response_body`, `operation`, `request_payload`) para que `Log error` lo registre completo
- `Log error` lee todo desde `$json.*` del output de `Recover status` (no referencia nodos no ejecutados)

> **Fix 2026-08-28:** `Log error` referenciaba `$('Create snipe-it status').item` / `$('Update snipe-it status').item` con ternario. Solo uno ejecuta por corrida → la referencia al otro evaluaba a vacío y `operation` quedaba en `"\n  "` (whitespace literal fuera del `{{ }}`). Además `response_status`/`error_message` leían `$json.statusCode`/`$json.body.messages` sobre `{found:false}`. Fix: `Recover status` propaga el error y `Log error` mapea `={{ $json.response_status }}` etc. Ver `docs/04-workflows-sincronizacion.md` §4.4.

#### Mapeo estado Tryton → tipo Snipe-IT

Usado en `Status asset` (knownTypes):

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

> **Nota archivos eliminados:** los workflows viejos en `flows/` (`Tryton sync models.json` ID `Q5X3iqntFS1etrPW`, `Tryton sync statuses.json` ID `CisxFC1TxerOtZkG` y otros) siguen dados de baja; los activos viven en `flows/flujos-dev/`.

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

Auditoría de operaciones contra Snipe-IT. Esquema en `public.integration_sync_log` (BD `n8n`).

- **Status flow:** `Log error` mapea `operation`/`request_payload`/`response_status`/`response_body`/`error_message` desde el output de `Recover status` (`found:false` propaga `error.message`/`status`, `desired_name`, y el JSON completo de la respuesta). **Fix 2026-08-28:** antes leía `$json.statusCode`/`$json.body.messages` sobre `{found:false}` y ternario sobre nodos no ejecutados → `operation` quedaba en `"\n  "`.
- **Categories flow:** `operation` hardcodeado a `"create"`; `request_payload` es `JSON.stringify($('Create snipe-it category').params.bodyParameters.parameters[1])` (solo el segundo parámetro).
- **Limitaciones generales:** `tryton_id` y `snipe_id` en `0` para categorías/estados; sin reconciliación de activos existentes; `SNIPE_HOST` debe ser `http://snipe-it:80` dentro de la red Docker (no `localhost`).

---

## Errores conocidos

| Caso | Comportamiento actual |
|------|----------------------|
| Modelo sin mapeo | `snipe_model_id` undefined → error JSON en `Create asset` |
| Nombre de modelo cambiado | PATCH automático |
| Nombre duplicado en Snipe-IT | POST falla; el modelo queda sin mapeo |
| Modelo borrado en Snipe-IT | Falso "existe" por el mapa; sin reconciliación |
| Categoría duplicada | **Self-heal:** busca en Snipe-IT por nombre y mapea si la encuentra |
| Categoría con comilla | `Search category` usa interpolación directa SQL; puede romper |
| `asset_model` o `actual_value` nulos | `Flatten assets` lanza error |
| Más de 100 activos | Sin paginación; solo los primeros 100 |
| Rate limit Tryton/Snipe-IT | 429 posibles en operación masiva |
| `SNIPE_HOST = localhost` dentro del stack | `ECONNREFUSED ::1:8080`; usar `http://snipe-it:80` |
| Pinned data en trigger de sub-workflow | `Unpin '<trigger>' to execute` al ejecutar desde orquestador; el trigger recibe datos del padre y n8n se niega a usar pinned data |
| `onError: continueRegularOutput` en HTTP | Errores se capturan como item `[{"error": "..."}]`; con `fullResponse:true` el item es `{error:{message,status}}` sin `statusCode`/`body` — no mapear `$json.statusCode`/`$json.body.messages` directamente |
| `Invalid key supplied` / `Key path ... not readable` en toda la API | Llaves Passport `oauth-*.key` perdidas (volumen anónimo destruido con el contenedor) o `root:root` sin permiso para `apache`. Fix: bind `./snipe-data/snipeit:/var/lib/snipeit` + `php artisan passport:keys --force` + `chown apache:apache` (ver `AGENTS.md`) |
| 401 `Unauthorized or unauthenticated.` en Snipe-IT | Credencial `Bearer Auth snipe-it` (`httpBearerAuth` id `Adhjdtilu8D9eQs8`) con PAT inválido/revocado. Regenerar en Snipe-IT (Admin → API Tokens) y actualizar en n8n |
| `$('Nodo').item` sobre nodo no ejecutado | En expresiones, referencia a nodo de la rama no tomada evalúa a vacío silenciosamente (ej. ternario `Create ? ... : Update ? ...` → `"\n  "`). Usar `Recover *` para propagar contexto en vez de ternario cruzado |
