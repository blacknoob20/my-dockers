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
| Tryton sync snipe-IT assets | Sub-workflow de negocio | `flows/flujos-dev/Tryton sync snipe-IT assets.json` | `v6K5kipkr7UKp0fE` |
| Tryton sync users assets (titular-activo v1) | Sub-workflow de negocio | `flows/flujos-dev/Tryton sync users assets.json` | `yjyUYjVEaZ9UniSs` |
| Tryton sync snipe-IT assets orchestrator v2 | Orquestador (batch) | `flows/flujos-dev/Tryton sync snipe-IT assets orchestrator v2 (batch).json` | `3hh7DBsrq8A1rIQg` |

> **Nota:** los archivos en `flows/` son snapshots de n8n. Al modificar un workflow en la UI, re-exportarlo para mantenerlos al día.

> **Archivos eliminados:** `flows/Tryton sync assets.json`, `flows/Tryton sync categories.json`, `flows/Tryton sync models.json`, `flows/Tryton sync snipe-IT assets orchestrator.json`, `flows/Tryton sync snipe-IT models.json`, `flows/Tryton sync snipe-IT status.json`, `flows/flujos-dev/Tryton sync snipe-IT assets ingest (batch).json` (`Asse2tIngestSub01`, snapshot stale del mismo workflow `v6K5kipkr7UKp0fE`) — todos con IDs muertos o duplicados.

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
- **ID:** `3hh7DBsrq8A1rIQg` — inactivo, se dispara manualmente
- **Nota:** los workflows viejos `flows/Tryton sync snipe-IT models.json` y `flows/Tryton sync snipe-IT status.json` (IDs muertos) fueron reemplazados por los sub-workflows en `flows/flujos-dev/` listados arriba
- **Orquesta (fase 1 — catálogos):** `Execute login` → `Search assets` → `Flatten assets` → `Category list`/`Status list` → `Split Out` por entidad → `Execute Tryton sync snipe-IT categories` / `Execute Tryton sync snipe-IT status` → `Wait categories & statuses` → `Model list` → `Execute Tryton sync snipe-IT models` (sub-workflows vía `Execute Workflow`; models sin `Split Out`: recibe el lote completo en 1 item y corre en modo once — ver Fix 2026-08-28 batch models)
- **Orquesta (fase 2 — batch PG activos):** `Execute Tryton sync snipeIT models` → `Prepare staging payload` (Code, `const assets = $('Flatten assets').first().json.result` → `payload: JSON.stringify(rows), total`) → `Execute ingest (batch)` (sub-workflow `Tryton sync snipe-IT assets ingest (batch)` vía `Execute Workflow`, inputs `{payload, total}`, `waitForSubWorkflow: true`) → `Sync titular activo` (sub-workflow `Tryton sync titular-activo (v1)` vía `Execute Workflow`). Ver detalle de `Execute ingest (batch)` en § Tryton sync snipe-IT assets ingest (batch).

> **Fix 2026-08-28 (PG-DDL):** los 6 nodos Postgres de la fase 2 (ahora en el sub-workflow `assets ingest`) apuntaban a `staging_tryton_assets`, `tryton_snipe_asset_map` y `sync_run_summary` que no existían en la BD `n8n` (`relation does not exist`). Se añadió DDL §5-7 a `sql/init-sync-tables.sql` y se aplicó; ver § Tablas de mapeo. El bloque `Run summary` se ejecuta con `executeOnce` y los `Upsert/Log error` con `onError: continueRegularOutput`.

> **Refactor 2026-08-28 (ingest sub-workflow):** fase 2 (staging/diff/loop/upsert/summary) extraída del orquestador al sub-workflow `Tryton sync snipe-IT assets ingest (batch)` (ID `Asse2tIngestSub01`) para mejorar mantenibilidad. El orquestador pasa `payload`/`total` vía `workflowInputs` y espera (`waitForSubWorkflow: true`); `Load staging (bulk)` relee desde `$('Tryton sync snipe-IT assets orchestrator').first().json.payload`. `Log error (batch)` en el sub registra `workflow_name = $workflow.name` del sub y `execution_id` del sub (conteo `api_errors` de `Run summary` queda consistente dentro de la ejecución del sub). El orquestador invoca `Sync titular activo` tras el ingest.

> **Fix 2026-08-28 (Wait models):** Merge `Wait models` (`mode: chooseBranch`, recibía por input 1 y salía por output 1 no conectado → fase 2 nunca disparaba) eliminado; `Execute Tryton sync snipeIT models` conecta directo a `Prepare staging payload`; `Prepare staging payload` migrado de `$('Wait models')` a `$('Flatten assets')`. `Wait categories & statuses` queda pendiente de análisis (mismo patrón `chooseBranch`, sólo hace passthrough del item de `Flatten assets`).

> **Fix 2026-08-28 (batch models):** con `Split Out models` + `Execute Tryton sync snipe-IT models` en modo `each`, cada modelo lanzaba una sub-ejecución completa del sub-workflow (≈0.5 s serial por modelo: arranque n8n + 1–2 queries PG `WHERE ... = $1` + HTTP). En el run 288 (2026-08-28) fueron 597 sub-ejecuciones = 331 s, ~100% de la duración del orquestador. Se eliminó `Split Out models` del orquestador (`Model list` pasa el lote en 1 item, `result` = array) y `Execute Tryton sync snipeIT models` quedó en modo once con `waitForSubWorkflow: true`. Dentro del sub: `Resolve batch models` (1 query con `jsonb_to_recordset($1)` LEFT JOIN `tryton_snipe_model_map` + `tryton_snipe_category_map`), `Prepare items` (Code `runOnceForAllItems`: filtra no-ops y marca `action: create|update`; en steady-state emite ~0 items), upsert bulk `Save models (bulk)` (`INSERT ... jsonb_to_recordset ... ON CONFLICT (tryton_model_id) DO UPDATE`) para el camino feliz; la rama self-heal/error queda por-item (`Save model (self-heal)`/`Log error`). El settings del sub fija `saveDataSuccessExecution: none` (antes se escribían ~4.8 MB de `execution_data` por run). Hot path: de ~3N queries PG + N sub-ejecuciones a 2 queries PG + 1 ejecución.

> **Fix 2026-08-31 (freeze UI):** `Search assets` (`model.asset.search_read`) usaba `0, null, null` (sin límite) → ~9.5k activos informática (≈10 MB `jsonSizeBytes`, runs 288/1053/1054 con 7-10 MB en `execution_entity`) congelaba el navegador al renderizar. Fix inicial: `0, 100, null` (límite 100, §4.1) + `settings.saveDataSuccessExecution: none / saveDataErrorExecution: all / saveExecutionProgress: false / executionTimeout: 3600` en los 6 workflows (`flows/flujos-dev/*`, `flows/tryton/Tryton login.json`, `v6K5kipkr7UKp0fE`) vía `UPDATE workflow_entity`. Con `100` solo se veían 23/558 modelos distintos (primeros 100 activos).
> **Fix 2026-08-31 (full fetch + Tag for save SET):** restaurado `Search assets` a `0, null, null` para traer 9565 activos y 558 modelos distintos (meta 597 del run 288) manteniendo `saveDataSuccessExecution: none` (no se guarda `execution_data`, no congela). `Tag for save` (`JODxuGjfCJ2wDobA:38f549da`) convertido de `Code runOnceForEachItem` a `Set 3.4` (7 campos mapeados por expresión, `includeOtherFields: false` por defecto) para reducir overhead del JS task runner; `Build save payload` quedó como `Code runOnceForAllItems` con `$input.all()`.

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
- **Trigger:** Execute Workflow Trigger (`Tryton sync snipe-IT assets orchestrator`, `inputSource: passthrough`)
- **Entrada:** 1 solo item con el lote completo: `{ "result": [ {asset_model_id, asset_model_name, category}, ... ] }` (output de `Model list` del orquestador, sin Split Out)
- **Invocado por:** orquestador v2 vía `Execute Tryton sync snipeIT models` (modo once, `waitForSubWorkflow: true`)

#### Flujo

```
Tryton sync snipe-IT assets orchestrator ({ result: [modelos] })
      ↓
Resolve batch models (1 query, executeOnce: jsonb_to_recordset($1::jsonb)
  LEFT JOIN tryton_snipe_model_map ON tryton_model_id
  LEFT JOIN tryton_snipe_category_map ON tryton_name
  → jsonb_agg con {snipe_model_id, map_tryton_name, snipe_category_id} por modelo)
      ↓
Prepare items (Code runOnceForAllItems: descarta modelos existentes sin cambio
  de nombre; emite 1 item por modelo pendiente con action: "create" | "update";
  pairedItem explícito. Sin pendientes emite 1 item `noop` para no vaciar la salida)
      ↓
Has work? (IF: $json.action != "noop")
   ├─ Sí → Create or update? (IF: $json.action == "create")
   │        ├─ create → Create snipe-it model (POST /models {category_id: $json.snipe_category_id, name, fieldset_id:2}, batching batchSize:1/batchInterval:1200) → Is SnipeIT Saved?
   │        └─ update → Update snipe-it model (PATCH /models/{id} {name, fieldset_id:2}, batching batchSize:1/batchInterval:1200) → Is SnipeIT Saved?
  └─ No (noop) → Finish (saca al menos 1 item para que el orquestador dispare la fase 2)
                     ↓
                 Is SnipeIT Saved? (body.status == "success")
                  ├─ Sí → Tag for save (Set por-item: mapea $('Prepare items') + body.payload → tryton_model_id/tryton_name/snipe_model_id/snipe_category_id/snipe_name/created_at/updated_at)
                  │         → Build save payload (Code runOnceForAllItems: JSON de filas)
                  │         → Save models (bulk) (INSERT ... jsonb_to_recordset ... ON CONFLICT (tryton_model_id) DO UPDATE, executeOnce) → Finish
                  └─ No → Find model in Snipe (rama self-heal, ver abajo)
```

#### Self-heal: auto-recuperación de modelos duplicados

```
Is SnipeIT Saved? == false
      ↓
Find model in Snipe (GET /api/v1/models?search=<name>, onError: continueRegularOutput, fullResponse: true)
      ↓
Recover model (Code: match exacto case-insensitive por name)
      ↓
Recovered model? (found == true)
  ├─ Sí → Save model (self-heal) (upsert tryton_snipe_model_map por-item) → Finish
  └─ No → Log error → Finish
```

- `Find model in Snipe`: `onError: continueRegularOutput` — en 401/500 devuelve `{error:{message,status}}` en vez de fallar
- `Recover model`: busca el match exacto y, en `found:false`, **propaga contexto de error** (`response_status`, `error_message`, `response_body`, `operation`, `request_payload`) para que `Log error` lo registre completo
- `Log error` lee todo desde `$json.*` del output de `Recover model` (no referencia nodos no ejecutados); el tryton_id se toma de `$('Prepare items').item.json.asset_model_id`
- La rama self-heal (`Save model (self-heal)`, `Log error`) queda deliberadamente por-item: solo corre en errores (raros); el hot path va en bulk

> **Fix 2026-08-28:** `Log error` y `Recover model` tenían el mismo bug que `status` antes de su fix: `Log error` leía `$json.statusCode`/`$json.body.messages` sobre `{found:false}` y `operation` hardcodeado a `"create"` con `request_payload`/`response_body` que referenciaban `Create snipe-it model` directamente (vacío si la rama de `Update` ejecutó o si el error vino de `Find`/`Recover`). Fix: `Recover model` propaga `response_status`/`error_message`/`response_body`/`operation`/`request_payload` y `Log error` mapea `={{ $json.* }}`. Ver `docs/04-workflows-sincronizacion.md` §4.3.

> **Fix 2026-08-31 (0 pendientes bloqueaba fase 2):** en steady-state `Prepare items` emitía 0 items → el sub devolvía 0 items → `Execute Tryton sync snipeIT models` sacaba 0 → `Prepare staging payload` nunca se disparaba y la fase 2 quedaba sin correr (staging/asset_map/summary vacíos). `Prepare items` ahora emite un item `noop` y `Has work?` lo rutea directo a `Finish` para garantizar ≥1 salida; el orquestador además fija `alwaysOutputData: true` en `Execute models` como red de seguridad. `Update snipe-it model` fija `onError: continueRegularOutput` para no tumbar el lote.

> **Fix 2026-08-31 (Build save payload):** `Build save payload` (Code `runOnceForAllItems`) usaba `$input.allItems()` — API inexistente → `TypeError: $input.allItems is not a function` (n8n 2.36.7, `JsTaskRunner.runForAllItems`). Fix: cambiado a `$input.all().map(i => i.json)` (`flows/flujos-dev/Tryton sync snipe-IT models.json:628`).

> **Fix 2026-08-31 (429 batching):** `Create snipe-it model`/`Update snipe-it model` sin batching generaban `429 Try spacing your requests out using the batching settings` (150/582 en `integration_sync_log` run 1101; luego 219/291 con `5/1000`). Fix: `options.batching.batch {batchSize:1, batchInterval:550}` + `retryOnFail:true/maxTries:4/waitBetweenTries:3000` en ambos HTTP (`flows/flujos-dev/Tryton sync snipe-IT models.json:287,376`) + restart n8n; 558 modelos en ~310s (109/min, bajo el cap 120/min) con 0 pérdidas.

> **Fix 2026-09-01 (self-heal models search=undefined):** `Find model in Snipe` usaba `encodeURIComponent($json.asset_model_name)`. Tras fallo de `Create snipe-it model` con `fullResponse: true`, el item es `{body, statusCode, headers}` sin `asset_model_name` → consultaba `search=undefined` (verificado `{"total":0}`) y nunca encontraba el modelo existente. Los 40 duplicados de Tryton (mismo `upper(trim(name))` ya sincronizado, ej. `M267E` ×4, `KB-0225` ×3) quedaban sin mapeo: `tryton_snipe_model_map` 557/597, `integration_sync_log` 40 con `snipe_id=0`/`response_status=200` (body del search vacío). Fix: `encodeURIComponent($('Prepare items').item.json.asset_model_name)` en `flows/flujos-dev/Tryton sync snipe-IT models.json:476` + `UPDATE workflow_entity id JODxuGjfCJ2wDobA` + backfill SQL de los 40 al `snipe_model_id` canónico (`DISTINCT ON upper(trim(tryton_name))`), resultando 597/597 en el map (557 `snipe_model_id` distintos, duplicados Tryton comparten Snipe-ID).

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

### Tryton sync titular-activo (v1)

- **Archivo:** `flows/flujos-dev/Tryton sync users assets.json` (ID `yjyUYjVEaZ9UniSs`, activo)
- **Trigger:** `Execute Workflow Trigger` (`Ejecutado por el orquestador`, `inputSource: passthrough`) + `Manual Trigger` (también corre manual)
- **Invocado por:** orquestador v2 vía `Sync titular activo` (`Execute Workflow` → `yjyUYjVEaZ9UniSs`, `waitForSubWorkflow: true`, inputs `{ok: true}`)
- **Credenciales:** `postgres` id `5PxGaDR3de2sou85` (`Postgres account`), `postgres` id `erpDbegob2bakRO` (`ERP dbegob2bak (lectura)`), `httpBearerAuth` id `Adhjdtilu8D9eQs8` (`Bearer Auth snipe-it` vía `$env.SNIPE_HOST`)
- **Fuente autoritativa:** empleados ACTIVOS con contrato vigente del ERP (`res_user.login` → `login@guayas.gob.ec`). Solo activos Tryton con `asset_type_new in [6,39,40,48,61,92]` y `current_owner != null` (filtro en `model.asset.search_read`)

#### Flujo

```
Ejecutado por el orquestador / Ejecutar manualmente
       ↓
Iniciar sesión en Tryton (Tryton login → Cnq2yvzVCRTKFld5, waitForSubWorkflow: true)
       ↓
Leer activos con titular (POST /dbegob2bak/ model.asset.search_read — retry 3×3s)
       ↓
Extraer activos y titulares (Code: filtra current_owner!=null, deduplica owner_ids → {assets:[{code, owner_id}], owner_ids, n_assets, n_owners})
       ↓
Consultar empleados activos (ERP) (SELECT ce/pp/cc/ru WHERE cc.state='done' AND ru.active AND ru.login LIKE '%.%' AND pp.id=ANY($1) ORDER BY cc.contract_date DESC)
       ↓
Construir titulares deseados (Code: titleCase nombres, construye {snipe_asset_tag, email, first_name, last_name} por activo con owner válido → {payload: JSON.stringify(rows), total})
       ↓
Limpiar tabla temporal (staging) (DELETE FROM staging_titular;)
       ↓
Cargar titulares en staging (INSERT INTO staging_titular SELECT * FROM jsonb_to_recordset($1) — $1 = $('Construir titulares deseados').first().json.payload)
       ↓
Precargar usuarios de Snipe-IT (GET /api/v1/users?limit=500, retry 3×2s) → Guardar mapa de usuarios (bulk) (INSERT INTO snipe_titular_user_map(email, snipe_user_id) SELECT LOWER(x.email), x.id FROM jsonb_to_recordset($1) ON CONFLICT DO UPDATE — $1 = body.rows[].map(email,id) filtrado no vacío)
       ↓
Calcular usuarios faltantes (SELECT jsonb_agg(DISTINCT ON (LOWER(email))) FROM staging_titular WHERE LOWER(email) NOT IN (SELECT email FROM snipe_titular_user_map) → payload)
       ↓
¿Hay usuarios faltantes? (IF payload notEmpty) → Extraer usuarios faltantes (Code → 1 item por email distinto con username/password) → Preparar datos del nuevo usuario → Crear usuario en Snipe-IT (POST /api/v1/users, onError→Crear alt) → Registrar usuario creado → Guardar usuario creado en mapa (BD) →┐  ↘ Usuarios listos (Code, collapse M→1, fan-in con Marcar error al crear usuario) →┐
                                  false (payload vacío) ────────────────────────────────────────────┘                                                                                          ↓
                                                             Guardar usuario creado en mapa (BD): ya en cadena anterior; Reintentar con username alternativo (POST /users, username sufijo) → Registrar usuario creado (alt) → Guardar usuario creado en mapa (BD) →┘  |  error alt → Marcar error al crear usuario (Set, status error) →┘  (fan-in 3→1)
                                                                                                                                                                                                                                              ↓
Contar activos sin mapeo (SELECT COUNT(*) FROM staging_titular s LEFT JOIN tryton_snipe_asset_map am ON am.snipe_asset_tag=s.snipe_asset_tag AND am.snipe_asset_id IS NOT NULL WHERE am.snipe_asset_tag IS NULL)
       ↓
Detectar cambios de titular (SELECT ... FROM staging_titular s JOIN tryton_snipe_asset_map am ON am.snipe_asset_tag=s.snipe_asset_tag AND am.snipe_asset_id IS NOT NULL LEFT JOIN snipe_titular_map tm ON tm.snipe_asset_tag=s.snipe_asset_tag LEFT JOIN snipe_titular_user_map um ON um.email=LOWER(s.email) WHERE s.email IS NOT NULL AND s.email<>'' AND (tm.snipe_asset_tag IS NULL OR tm.email IS DISTINCT FROM s.email))
        ↓
¿Titular ya mapeado en BD? (IF existing_user_id notEmpty) → Usar usuario del mapa (Set, snipe_user_id=existing, created_user=false) →┐
                                                    ↓ false → Marcar usuario no disponible (Set, status error, snipe_user_id=existing_user_id) →┐
                                                                                                                                                ↓ (fan-in 2→1: ok + error sin usuario)
                                                                                                                                                                             Preparar asignación (Set, solo rama ok) → Asignar activo al titular (checkout) (POST /api/v1/hardware/{id}/checkout, retry 3×2s, onError→Liberar activo (checkin)) → Registrar asignación exitosa (Set, status ok) →┐
                                                                                                                                                                                                                                                         ↓ error → Liberar activo (checkin) (POST /checkin) → Reintentar asignación (POST /checkout, retry 3×2s) → Registrar asignación exitosa (tras reintento) (Set, status ok) →┤
                                                                                                                                                                                                                                                                                                   ↓ error → Registrar error de asignación (Set, status error) →┤
                                                                                                                                                                                                                                                                                                                                        ↓ (fan-in 4→1: ok + ok reintento + error checkout + usuario no disponible)
                                                                                                                                                                                                                                                                                                                                                                                                                                                                    Preparar asignación (Set, solo rama ok) → Asignar activo al titular (checkout) (POST /api/v1/hardware/{id}/checkout, retry 3×2s, onError→Liberar activo (checkin)) → Registrar asignación exitosa (Set, status ok) →┐
                                                                                                                                                                                                                                                          ↓ error → Liberar activo (checkin) (POST /checkin) → Reintentar asignación (POST /checkout, retry 3×2s) → Registrar asignación exitosa (tras reintento) (Set, status ok) →┤
                                                                                                                                                                                                                                                                                                    ↓ error → Registrar error de asignación (Set, status error) →┤
                                                                                                                                                                                                                                                                                                                                         ↓ (fan-in 4→1: ok + ok reintento + error checkout + usuario no disponible)
                                                                                                                                                                                                                                                                                       Package Results (Code, fan-in 4→1 → {payload, total, ok, errores, usuarios_nuevos}, 8000 items → 1)
         ↓ (fan-out 1→4, bulk)
   ┌──────────────┬──────────────────────┬─────────────────┐
   ↓              ↓                      ↓                 ↓
 Guardar usuarios en mapa (bulk)  Guardar titulares en mapa (bulk)  Registrar errores en bitácora (bulk)  Calcular resumen de sincronización (Code: lee $('Package Results').first().json.{ok,errores,usuarios_nuevos} + $('Detectar cambios').all().length + $('Contar activos sin mapeo') → {cambios, aplicados, errores, omitidos, usuarios_nuevos})
 (INSERT ... jsonb_to_recordset($1)     (INSERT ... jsonb_to_recordset($1)            (INSERT ... jsonb_to_recordset($3)                              ↓
  WHERE status='ok' DISTINCT ON(email)   WHERE status='ok' DISTINCT ON(tag)           WHERE status='error'                                   Guardar resumen en bitácora (INSERT integration_sync_log operation='run_summary')
```

- `Extraer activos y titulares` (Code, `runOnceForAllItems`): recibe 1 item cuyo `json.result` es el array completo del `search_read` (miles de activos `{id, code, current_owner}`); en una sola pasada filtra `current_owner != null`, construye `assets: [{code, owner_id}]` — consumido por `Construir titulares deseados` vía `$('Extraer activos y titulares').first().json.assets` — y deduplica `owner_ids: [...new Set(...)]` — consumido por `Consultar empleados activos (ERP)` como `= ANY($1)`; emite `n_assets`/`n_owners` para observabilidad. **Nota de diseño:** no es un `Set` 3.4 porque requeriría duplicar el `filter/map` en dos expresiones distintas (dos pasadas) y la dedup con `new Set(...)` en expresión es ilegible; el Code lo resuelve en una pasada y es el punto de referencia por nombre de los nodos aguas abajo. Se mantiene como `Code` intencionalmente.
- `Iniciar sesión en Tryton` usa sub-workflow `Tryton login` (`Cnq2yvzVCRTKFld5`); ambos triggers (`Ejecutado por el orquestador`, `Ejecutar manualmente`) confluyen en este nodo. Patrón staging+diff idempotente — solo aplica cambios (nuevo titular o titular distinto). No revoca checkouts (ver § Limitaciones).
- `Leer activos con titular` con `retryOnFail 3×3s` cubre 429 agresivo de Tryton (un solo `search_read` con `offset 0, limit null`, sin paginación, sobre ~19k assets filtrados).
- `Consultar empleados activos (ERP)`: filtra `login LIKE '%.%'` (login debe contener punto, coincide con AD/Zammad `login@guayas.gob.ec`) y elige el contrato más reciente por `DISTINCT ON (pp.id) ORDER BY cc.contract_date DESC`.
- `Detectar cambios de titular`: captura `tm IS NULL` (activo nunca asignado en Snipe) o `email IS DISTINCT FROM s.email` (cambio de titular). Assets cuyo `snipe_asset_id IS NULL` (sin mapa de activo, aún no sincronizado por el ingest) se excluyen y se cuentan aparte como `omitidos`.
- **Precarga bulk de usuarios (Fase A, antes del diff):** `Precargar usuarios de Snipe-IT` (`GET /api/v1/users?limit=500`, `httpBearerAuth` `Adhjdtilu8D9eQs8`, `retryOnFail 3×2s`, 1 petición para ~74 usuarios) → `Guardar mapa de usuarios (bulk)` (`INSERT ... jsonb_to_recordset($1) AS x(email text, id int) WHERE x.email<>'' ON CONFLICT (email) DO UPDATE`, `$1 = body.rows.map(email=>LOWER(email), id)` filtrado no vacío) → `Calcular usuarios faltantes` (`SELECT jsonb_agg(DISTINCT ON (LOWER(email))) FROM staging_titular WHERE LOWER(email) NOT IN (SELECT email FROM snipe_titular_user_map)` → `{payload: [...]|null}`) → `¿Hay usuarios faltantes?` (`payload` notEmpty) → `Extraer usuarios faltantes` (Code `if (!payload) return []`, mapea a `{email, first_name, last_name, username, password}` por email distinto — 1 por email, ~626 en primera corrida) → `Preparar datos del nuevo usuario` (lee `$json.email/first_name/last_name/username/password`, fallback a `email.split('@')[0]`) → `Crear usuario en Snipe-IT` (`POST /api/v1/users`, `first_name/last_name` con fallback, `onError→Crear alt`, batching 20/500ms) → `Registrar usuario creado` (`created_user=true`) → `Guardar usuario creado en mapa (BD)` (`INSERT ... $json.email/$json.snipe_user_id`); en colisión de `username` → `Reintentar con username alternativo` (username sufijo `.`+rand4) → `Registrar usuario creado (alt)` → `Guardar usuario creado en mapa (BD)`; ambos fallan → `Marcar error al crear usuario` (`status error`); `Usuarios listos` (Code `return [{json:{ok:true}}]` colapsa M→1, fan-in de `Guardar usuario creado en mapa (BD)` + `Marcar error al crear usuario`) — la rama `false` de `¿Hay usuarios faltantes?` va directo a `Contar activos sin mapeo`.
- `Detectar cambios de titular`: captura `tm IS NULL` o `email IS DISTINCT FROM s.email` con guarda `s.email IS NOT NULL AND s.email<>''` y join `um.email = LOWER(s.email)` (emails cacheados siempre en minúsculas). Assets sin `snipe_asset_id` se excluyen y se cuentan como `omitidos`.
- `¿Titular ya mapeado en BD?` / `Usar usuario del mapa` / `Marcar usuario no disponible`: resuelven `snipe_user_id` **sin búsquedas HTTP**. Si `existing_user_id` existe (cache completa tras precarga+creación) → `Usar usuario del mapa` (cache `snipe_titular_user_map`, `snipe_user_id=existing`, `created_user=false`); si no (usuario no creado o error), → `Marcar usuario no disponible` (`status error`, no entra a checkout). **Nodos eliminados 2026-09-03:** `Buscar usuario por email en Snipe-IT` (`GET /api/v1/users?email=&limit=1`), `¿Usuario existe en Snipe-IT?` y `Usar usuario existente de Snipe-IT` — su función la cubre la precarga bulk + dedup por email.
- `Preparar asignación` (Set, fan-in 1: solo rama `Usar usuario del mapa` — el `Marcar usuario no disponible` ya salió a `Consolidar resultados`) checkpoint antes del checkout; `Asignar activo al titular (checkout)` (`POST /api/v1/hardware/{id}/checkout` `{checkout_to_type:user, assigned_user, note}`, `retryOnFail 3×2s`, `batching 20/500ms`, `onError: continueErrorOutput`) → `Registrar asignación exitosa` (`status ok`); en error → `Liberar activo (checkin)` (`POST /checkin` `{note}`, `onError: continueRegularOutput`) → `Reintentar asignación` (mismo body, `retryOnFail 3×2s`) → `Registrar asignación exitosa (tras reintento)` / `Registrar error de asignación` (`status error` con `error_message/response_status/response_body` del `error`/`body`). Corre en proceso principal de n8n (sin límite `N8N_RUNNERS_TASK_TIMEOUT` del task runner).
- `Package Results` (Code, `runOnceForAllItems`, fan-in 4→1 de `Registrar asignación exitosa` + `Registrar asignación exitosa (tras reintento)` + `Registrar error de asignación` + `Marcar usuario no disponible` → 1 item `{payload, total, ok, errores, usuarios_nuevos}` con `payload=JSON.stringify(rows)`). Contrato de 1 item: los 3 nodos bulk leen `$('Package Results').first().json.payload` y filtran por `status` en SQL.
- `Guardar usuarios en mapa (bulk)` (`INSERT INTO snipe_titular_user_map ... SELECT DISTINCT ON (x.email) ... FROM jsonb_to_recordset($1::jsonb) AS x(...) WHERE x.status='ok' ORDER BY x.email ON CONFLICT (email) DO UPDATE`) y `Guardar titulares en mapa (bulk)` (ídem por `snipe_asset_tag`) — **bulk**: 8000 filas en 1 query cada uno, con `DISTINCT ON` para evitar `ON CONFLICT DO UPDATE cannot affect row a second time` cuando un titular tiene N activos (mismo email repetido). `Registrar errores en bitácora (bulk)` (`INSERT INTO integration_sync_log ... SELECT $1,$2 ... FROM jsonb_to_recordset($3::jsonb) WHERE x.status='error'`). Eliminado `¿Asignación exitosa?` (el filtro lo hace el `WHERE` en cada bulk).
- `Calcular resumen de sincronización` (lee `Package Results` stats `ok/errores/usuarios_nuevos` + `Detectar cambios` `all().length` + `Contar activos sin mapeo` `omitidos`) → `Guardar resumen en bitácora` deja siempre una fila `run_summary` (`entity='titular'`) con `{cambios, aplicados, errores, omitidos, usuarios_nuevos}`.
- Tablas del patrón (§ Tablas de mapeo): `staging_titular`, `snipe_titular_user_map`, `snipe_titular_map`.

> **Fix 2026-09-01 (referencia huérfana login + SNIPE_TOKEN):** `Iniciar sesión en Tryton` apuntaba a `RuVLU1TOMoOxqVE3` (Tryton login borrado; ya corregido en `Tryton sync snipe-IT status` a `Cnq2yvzVCRTKFld5` según memoria 2026-08-28). Además `Consolidar resultados` usaba `$env.SNIPE_TOKEN` inexistente en `envs/n8n.env` (la var es `SNIPEIT_TOKEN`) → `Bearer undefined` → 401 masivo (`staticData.lastRun` 200 cambios/0 aplicados/200 errores 401). `Leer activos con titular` usaba `$env.TRYTON_HOST` (los demás workflows usan `TRYTON_URL`). Fix: repuntado a `Cnq2yvzVCRTKFld5`, alineado a `$env.SNIPEIT_TOKEN || $env.SNIPE_TOKEN` y a `($env.TRYTON_URL || $env.TRYTON_HOST)`, más `retryOnFail 3×3s` en `Leer activos con titular` y retry 2×1.5s/3s en `api()` del Code. Ver `flows/flujos-dev/Tryton sync titular-activo.json:45,89,228` y `docs/04` §4.6.

> **Fix 2026-09-01 (observabilidad titular):** errores de `Consolidar resultados` se tragaban (solo `staticData.lastRun`, que no persiste en runs manuales ni si la ejecución fallaba temprano; el workflow terminaba en `success` con 0 aplicados). Fix: `Consolidar resultados` retorna `status:'ok'|'error'` por fila; nuevo IF `¿Asignación exitosa?` → `Upsert *` (ok) / `Registrar error en bitácora` (error, `integration_sync_log` `titular_checkout` con `response_status/response_body/error_message`); nuevos `Contar activos sin mapeo` (staging sin `asset_map`) + `Calcular resumen de sincronización` → `Guardar resumen en bitácora` (`run_summary` `entity='titular'` siempre, con `{cambios, aplicados, errores, omitidos, usuarios_nuevos}`). `integration_sync_log` pasa a ser auditoría completa del titular; `staticData.lastRun` sigue como cache local.

> **Decisión 2026-09-01 (no-revocación):** el patrón solo asigna/reasigna; si el titular deja de serlo en ERP (`current_owner = null`) o el empleado sale (`ru.active=false` o sin contrato `done`), el activo queda checkout al titular anterior en Snipe-IT. No se hace `checkin` automático de revocado. Intencional por ahora (evita des-asignaciones masivas ante lag del ERP); pendiente definir política y registrar aquí cuando cambie. Documentado como limitación.

> **Fix 2026-09-02 (settings de ejecución):** workflow creado el 2026-09-01 sin heredar el endurecimiento del fix 2026-08-31 (`saveDataSuccessExecution: none` / `saveDataErrorExecution: all` / `saveExecutionProgress: false` / `executionTimeout: 3600`); cada corrida guardaba el output de ~10 nodos × 8000 items en `execution_entity` (~10-30 MB/run) y congelaba el navegador. Fix: `settings` alineados a `Tryton sync snipe-IT status`/`models`/`ingest` vía `UPDATE workflow_entity SET settings` (`yjyUYjVEaZ9UniSs`) + `docker compose restart n8n` y snapshot sincronizado; ID corregido de `nocNCHrMCVe36Qxr` (obsoleto) a `yjyUYjVEaZ9UniSs`.

> **Fix 2026-09-02 (cola DB bulk, 16k→3 queries):** `Consolidar resultados` con 8000 items alimentaba `¿Asignación exitosa?` (IF ×8000) → `Guardar usuario en mapa (BD)` + `Guardar titular en mapa (BD)` (2×8000 queries `INSERT ... ON CONFLICT` por item) + `Registrar error en bitácora` (N queries). Cada query 1 round-trip. Fix: `Package Results` (Code, 8000→1 `{payload, ok, errores, usuarios_nuevos}`) + 3 queries bulk con `jsonb_to_recordset($1::jsonb) WHERE status=...` + `DISTINCT ON (email/tag)` + `ON CONFLICT DO UPDATE` (8000 filas en 1 query cada una, sin `cannot affect row a second time` cuando un email tiene N activos). Eliminado `¿Asignación exitosa?` (filtro en `WHERE`). `Calcular resumen` lee `Package Results` stats. Snapshot 45→44 nodos, `UPDATE workflow_entity yjyUYjVEaZ9UniSs` + `restart n8n`; spec y `docs/04` §4.6 sincronizados.

> **Fix 2026-09-03 (precarga bulk titulares + eliminación búsqueda per-item):** `Buscar usuario por email en Snipe-IT` (`GET /api/v1/users?email=&limit=1`, `batching 20/500ms`, `retryOnFail 3×2s`, `onError: continueErrorOutput`) ejecutaba 1 HTTP por fila: `Detectar cambios de titular` con 8,991 items y `snipe_titular_user_map` vacío → 8,991 GETs, solo **96 en salida éxito y 8,895 en salida error (8,541 `timeout of 30000ms`, resto `ETIMEDOUT`/`ECONNRESET`/`EAI_AGAIN`)** en ejecución 1487, `executionTime` 2,991,056 ms (~50 min solo en ese nodo, Snipe-IT 804% CPU, DNS docker `EAI_AGAIN`). Cada corrida repetía el mismo costo porque la corrida nunca llegaba a `Guardar usuario en mapa (BD)`. Además 1 request por `snipe_asset_tag` con N=8,991 y solo **74 usuarios en Snipe-IT**; con `email=''` Snipe devuelve el primer usuario de todos (falso match). Y 1 creación por *asset* (no por *email distinto*: 698 emails → ~13 intentos duplicados por email → usuarios duplicados con username `.`+rand). Fix: precarga bulk **antes del diff**: `Precargar usuarios de Snipe-IT` (1 GET `/api/v1/users?limit=500`) → `Guardar mapa de usuarios (bulk)` (`INSERT ... jsonb_to_recordset($1) LOWER(email) ON CONFLICT DO UPDATE`) → `Calcular usuarios faltantes` (`DISTINCT ON LOWER(email)` no en mapa) → `¿Hay usuarios faltantes?` → `Extraer usuarios faltantes` (Code 1 por email distinto con `username/password`) → `Preparar datos del nuevo usuario` (lee `$json`) → `Crear usuario en Snipe-IT`/`Reintentar alt` → `Guardar usuario creado en mapa (BD)` + `Usuarios listos` (Code colapsa M→1); rama `false` del IF va directo a `Contar activos sin mapeo`. `Detectar cambios` añade guarda `s.email<>''` y join `um.email=LOWER(s.email)`. `¿Titular ya mapeado en BD?` ya sin HTTP: `true`→`Usar usuario del mapa`→checkout, `false`→`Marcar usuario no disponible`→`Consolidar resultados` (sin checkout). Eliminados del flujo: `Buscar usuario por email en Snipe-IT`, `¿Usuario existe en Snipe-IT?`, `Usar usuario existente de Snipe-IT`. Snapshot 37→45 nodos (`flows/flujos-dev/Tryton sync titular-activo.json`), `UPDATE workflow_entity yjyUYjVEaZ9UniSs` + `docker compose restart n8n`; spec y `docs/04` §4.6 sincronizados.

> **Fix 2026-09-03 (nombres EN — Tryton sync users assets):** snapshot `Tryton sync users assets.json` (ID `yjyUYjVEaZ9UniSs`, mismo workflow que `titular-activo`, 45 nodos) renombró 39 nodos funcionales de ES a EN corto Title Case sin mover `position`/`id`/`type`/`credentials`/`settings`. Trigger `Tryton sync snipe-IT assets orchestrator` y 5 stickies (`Sticky Note*`, `Capítulo 3: Aplicar en Snipe-IT`) se mantuvieron ES. Conexiones y `$('...')` (`Extract Asset Owners`, `Build Owners`, `Preload Snipe Users`, `Prep New User`, `Prep Assignment`, `Merge Results`, `Detect Changes`, `Count Unmapped`) actualizadas. Mapeo: `Iniciar sesión en Tryton`→`Tryton Login`, `Leer activos con titular`→`Read Owned Assets`, `Extraer activos y titulares`→`Extract Asset Owners`, `Consultar empleados activos (ERP)`→`Query Active Employees`, `Construir titulares deseados`→`Build Owners`, `Limpiar tabla temporal (staging)`→`Clear Staging`, `Cargar titulares en staging`→`Stage Owners`, `Precargar usuarios de Snipe-IT`→`Preload Snipe Users`, `Guardar mapa de usuarios (bulk)`→`Bulk Save Users`, `Calcular usuarios faltantes`→`Find Missing Users`, `¿Hay usuarios faltantes?`→`Missing Users?`, `Extraer usuarios faltantes`→`Get Missing Users`, `Preparar datos del nuevo usuario`→`Prep New User`, `Crear usuario en Snipe-IT`→`Create Snipe User`, `Registrar usuario creado`→`Tag New User`, `Reintentar con username alternativo`→`Retry Alt Username`, `Registrar usuario creado (alt)`→`Tag New User (Alt)`, `Marcar error al crear usuario`→`Mark Create Failed`, `Guardar usuario creado en mapa (BD)`→`Save New User`, `Usuarios listos`→`Users Ready`, `Contar activos sin mapeo`→`Count Unmapped`, `Detectar cambios de titular`→`Detect Changes`, `¿Titular ya mapeado en BD?`→`Owner Mapped?`, `Usar usuario del mapa`→`Use Mapped User`, `Marcar usuario no disponible`→`Mark No User`, `Preparar asignación`→`Prep Assignment`, `Asignar activo al titular (checkout)`→`Checkout Asset`, `Registrar asignación exitosa`→`Checkout OK`, `Liberar activo (checkin)`→`Checkin Asset`, `Reintentar asignación`→`Retry Checkout`, `Registrar asignación exitosa (tras reintento)`→`Checkout OK (Retry)`, `Registrar error de asignación`→`Checkout Failed`, `Consolidar resultados`→`Merge Results`, `¿Asignación exitosa?`→`Checkout OK?`, `Guardar usuario en mapa (BD)`→`Upsert User`, `Guardar titular en mapa (BD)`→`Upsert Owner`, `Registrar error en bitácora`→`Log Error`, `Calcular resumen de sincronización`→`Build Summary`, `Guardar resumen en bitácora`→`Save Summary`. Validado: 45 nodos, 0 refs ES, diff `position` vacío. Espejo en `docs/04-workflows-sincronizacion.md` §4.6.

### Tryton sync snipe-IT assets

- **Archivo:** `flows/flujos-dev/Tryton sync snipe-IT assets.json` (ID `v6K5kipkr7UKp0fE`, activo — **canónico**; el archivo `ingest (batch).json` `Asse2tIngestSub01` era un snapshot stale duplicado del mismo workflow y fue eliminado)
- **Trigger:** Execute Workflow Trigger (`Tryton sync snipe-IT assets orchestrator`, `inputSource: passthrough`, antes `Tryton sync snipe-IT assets orchestrator`)
- **Entrada:** `{ "payload": "<json-array-string>", "total": 100 }` desde `Prepare staging payload` del orquestador (`payload = JSON.stringify(rows)` donde cada row es `{tryton_asset_id, code, internal_code, name, asset_state, tryton_model_id, tryton_model_name, category_name}`)
- **Invocado por:** orquestador v2 vía `Execute ingest (batch)` (`waitForSubWorkflow: true`, workflow `v6K5kipkr7UKp0fE`)
- **Credenciales:** `postgres` id `qJJfZl7PuKahcYb0`, `httpBearerAuth` id `Adhjdtilu8D9eQs8` (Bearer Snipe-IT)

#### Flujo

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
             Diff assets (batch) (SELECT ... FROM staging_tryton_assets s JOIN tryton_snipe_model_map m ON m.tryton_model_id = s.tryton_model_id AND m.snipe_model_id IS NOT NULL JOIN tryton_snipe_status_map st ON st.tryton_name = s.asset_state LEFT JOIN tryton_snipe_asset_map am ON am.tryton_asset_id = s.tryton_asset_id WHERE IS DISTINCT — calcula action='create'|'update')
                ↓
              Any changes? (IF $json.action notEmpty)
               ├─ true  → Batch changes (splitInBatches, **batchSize 1** secuencial — deliberado para no disparar `429 api-throttle:api`; ver nota 1×1)
               │              ↓ (done)           ↓ (each)
               │           Run summary        Create or update? (IF $json.action == 'create')
               │           (ver guarda        ├─ true  → Create snipe-IT asset (batch) (POST /api/v1/hardware {name, asset_tag, status_id, model_id, _snipeit_internal_code_2})
               │            post-loop)       └─ false → Update snipe-IT asset (batch) (PATCH /api/v1/hardware/{snipe_asset_id} {name, asset_tag, status_id, model_id, _snipeit_internal_code_2})
                │                                              ↓
                │                                           Saved? (IF body.status == "success", antes `Saved?`)
                │                                            ├─ true  → Upsert asset map (INSERT INTO tryton_snipe_asset_map ... ON CONFLICT (tryton_asset_id) DO UPDATE) → Loop → Batch changes
                │                                            └─ false → Find asset in Snipe (GET /api/v1/hardware?asset_tag={{code}}, fullResponse, onError: continueRegularOutput)
                │                                                         ↓
                │                                                      Recover asset (Code: match exact asset_tag en body.rows; encontrado → {found:true, body:{payload:{id, asset_tag, name}}}; no → propaga response_status/error_message/response_body/operation del Create/Update original)
                │                                                         ↓
                │                                                      Recovered asset? (IF $json.found, antes `Recovered asset?`)
                │                                                        ├─ true  → Upsert asset map (mismo nodo, body.payload normalizado) → Loop → Batch changes
                │                                                        └─ false → Log error (batch) (INSERT INTO integration_sync_log ...) → Loop → Batch changes
                └─ false → Run summary (INSERT INTO sync_run_summary (run_id, total_tryton, to_create, to_update, unchanged, missing_model, deleted_in_tryton, api_errors) SELECT ... FROM staging ... RETURNING *, executeOnce)
                             ↓
                          Has API errors? (IF ($json.api_errors ?? 0) > 0)
                            ├─ true  → Fail: ingest had API errors (Stop and Error) → api_errors > 0, revisar integration_sync_log
                            └─ false → Finish (success)
```

- `Check custom field internal_code` / `Has internal_code field?` / `Fail: missing custom field`: **pre-flight**. Verifica `GET /api/v1/fields` y que exista `db_column_name === '_snipeit_internal_code_2'` (id 2). Si falta, falla en ~1 s con mensaje accionable (ejecutar `scripts/snipe-it_custom_fields.sh`) en vez de procesar 8k assets 50 min para que todos fallen con `_snipeit_internal_code_2 does not seem to exist`. *Prerequisito:* `scripts/snipe-it_custom_fields.sh` (idempotente) crea el custom field `internal_code` (text, ANY) → `_snipeit_internal_code_2`, el fieldset id 2 (`Activos Tryton`) y los asocia. Ver `docs/manual-implementacion.md` §7.
- `Find asset in Snipe` / `Recover asset` / `Recovered asset?` (antes `Recovered asset?`): **self-heal assets** (replica patrón `Recover model`). Cuando `Create/Update snipe-IT asset` falla (p.ej. `asset_tag must be unique` por 383 assets huérfanos tras cancelación a mitad de loop), busca el asset existente por `asset_tag` exacto (`GET /api/v1/hardware?asset_tag=X`, `=`, `encodeURIComponent($('Batch changes').item.json.code)`, ver `AssetsController:309`) y si lo encuentra normaliza `body.payload` → `Upsert asset map` (`Recover` propaga `tryton_id`/`operation` y `Log error` lee `$json.*`). Así la re-ejecución corrige los huérfanos sin SQL manual. Log solo si realmente no existe.
- `Has API errors?` / `Fail: ingest had API errors`: **guarda post-loop**. Tras `Run summary`, si `api_errors > 0` el sub-workflow pasa a `error` (visible en n8n) en vez de `success` engañoso. Causa 2026-09-01: `api_errors=6314/8132` pero ejecución en `success` porque `Saved? → Log error → Batch changes` nunca levantaba error. `Log error` lee `$json.*` propagado por `Recover asset` (no `$('Batch changes').item` cruzado) para evitar `continueRegularOutput` silencioso.
- `Create/Update snipe-IT asset (batch)`: `batchSize:1, batchInterval:550` + `retryOnFail (4×, 3s)` + `onError: continueRegularOutput` + `fullResponse: true` — evita `429` de Snipe-IT (throttle 60/min, ver `api-throttle:api`) y reintenta; errores aún pasan a `Saved?`.
- `Upsert asset map` / `Log error (batch)` / `Loop` (antes `Loop`): `onError: continueRegularOutput`, `alwaysOutputData: true` — el loop continúa aunque el upsert/log falle. `Loop` es noOp puente hacia `Batch changes`.
- `Run summary` + `Finish`: `executeOnce: true`; `Run summary` cuenta `api_errors` con `COUNT(*) FROM integration_sync_log WHERE execution_id = $execution.id` (mismo `execution_id` del sub); `Has API errors? false` → `Finish` (noOp éxito).
- **Nota `workflow_name`:** `Log error (batch)` registra `$workflow.name` del **sub-workflow** (no del orquestador). Es el comportamiento elegido tras el refactor; ver nota en orquestador v2.

> **Fix 2026-09-01 (custom field internal_code faltante — 0 assets):** ejecución orquestador 1265 / ingest 1266 (`success` pero 0 assets, `sync_run_summary` 9565 total / 8132 to_create / 6314 api_errors, `tryton_snipe_asset_map` 0, `snipeit.assets` 0): la BD solo tenía 1 custom field (`MAC Address`, id 1) y 1 fieldset (id 1); faltaba el custom field `internal_code` → `${SNIPE_HOST}/api/v1/fields` vacío para `_snipeit_internal_code_2` y el fieldset id 2 (`Activos Tryton`, referenciado por `models.fieldset_id=2`). Todos los POST `/hardware` devolvían `200 {"status":"error","messages":{"_snipeit_internal_code_2":["This field does not seem to exist..."]}}`. Fix: añadida guarda pre-flight `Check custom field internal_code` → `Has internal_code field?` → `Fail: missing custom field` (falla rápido con instrucción de ejecutar `scripts/snipe-it_custom_fields.sh`), y guarda post-loop `Has API errors?` → `Fail: ingest had API errors` para que cualquier `api_errors > 0` marque la ejecución como `error`. Script `scripts/snipe-it_custom_fields.sh` idempotente (GET/POST `/api/v1/fields` y `/api/v1/fieldsets`, associate vía `/fields/{id}/associate`) + nota en `docs/manual-implementacion.md`; re-exportado snapshot `flows/flujos-dev/Tryton sync snipe-IT assets ingest (batch).json` (21 nodos con Loop/Finish); re-ejecutar orquestador tras provisioning crea los assets.

> **Fix 2026-09-01 (self-heal assets — 383 huérfanos tras cancelación):** tras cancelar ejecuciones a mitad de loop (1269/1270/1315), 383 assets quedaron en `snipeit.assets` sin fila en `tryton_snipe_asset_map` (create OK, `Upsert` no llegó). Sin self-heal la re-ejecución reintentaba `create` → `asset_tag must be unique` → `api_errors>0` perpetuo. Fix: añadidos `Find asset in Snipe` (GET `/api/v1/hardware?asset_tag=X`, `=`) → `Recover asset` (match exacto, normaliza `body.payload`) → `Recovered asset?` → `Upsert asset map` (reusa nodo) en rama `Saved? false`. La re-ejecución corrige los 383 y crea los ~3.9k restantes; no hay duplicados en staging (`0` códigos duplicados verificado: `SELECT code GROUP BY HAVING COUNT>1` = 0).

> **Fix 2026-09-03 (libro abierto — assets):** `Tryton sync snipe-IT assets` (26 nodos, 1 sticky genérico) con nombres ambiguos (`Batch changes`, `Loop`, `Saved?`, `Without changes`) obligaba a abrir expresiones/`$()` para entender el flujo. Fix: añadidos **5 headers** `Capítulo 1–5` (guardas, staging+diff, lote+self-heal, auditoría, camino sin cambios) + **4 micro-notas** (batch 1×1 anti-429, keep-alive `Without changes`, normalización `Recover asset`, gate `¿API errors?`) con contratos y referencias `workflow_name`/`api_errors`; **reposicionados** `Without changes`/`Continue`/`Loop` para flujo lineal; **7 nodos revisados manteniendo inglés** (`Tryton sync snipe-IT assets orchestrator`, `Batch changes`, `Loop`, `Without changes`, `Continue`, `Saved?`, `Recovered asset?` — con aclaraciones ` (1×1)` y notas) y 5 expresiones `$()` sincronizadas; snapshot stale `ingest (batch).json` (`Asse2tIngestSub01`, 24 nodos, 2 sin `Continue/Without changes`) eliminado y `assets.json` `v6K5kipkr7UKp0fE` 35 nodos promovido a canónico, `UPDATE workflow_entity v6K5kipkr7UKp0fE` + `docker compose restart n8n`; `docs/04` §4.5 sincronizado. *Revisión 2026-09-03 tarde:* traducciones a español de los 7 nodos revertidas — se mantienen nombres en inglés por convención del repo.

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
- **Models flow:** `Log error` mapea `operation`/`request_payload`/`response_status`/`response_body`/`error_message` desde el output de `Recover model` (`found:false` propaga `error.message`/`status`, `asset_model_name`, y el JSON completo de la respuesta). **Fix 2026-08-28:** antes leía `$json.statusCode`/`$json.body.messages` sobre `{found:false}` y `operation` hardcodeado a `"create"` con `request_payload`/`response_body` que referenciaban `Create snipe-it model` directamente.
- **Categories flow:** `operation` hardcodeado a `"create"`; `request_payload` es `JSON.stringify($('Create snipe-it category').params.bodyParameters.parameters[1])` (solo el segundo parámetro).
- **Titular flow:** `Log error titular` mapea `operation='titular_checkout'` por cada fila con `status='error'` (`response_status/response_body/error_message` desde el Code, con `_httpStatus` si hubo HTTP); `Log resumen titular` inserta `operation='run_summary'`, `entity='titular'` con `response_body=JSON({cambios, aplicados, errores, omitidos, usuarios_nuevos})` y `error_message='ok …'` o `'errores=… omitidos=…'` (auditoría siempre, independiente de `staticData.lastRun`). **Fix 2026-09-01:** antes solo `staticData.lastRun` (no persistente en manual/early-fail).
- **Limitaciones generales:** `tryton_id` y `snipe_id` en `0` para categorías/estados/titular; sin reconciliación de activos existentes; `SNIPE_HOST` debe ser `http://snipe-it:80` dentro de la red Docker (no `localhost`).

### `staging_tryton_assets` — orquestador v2 (batch)

Tabla efímera por ejecución. Se hace `DELETE` al inicio y `INSERT` masivo desde `jsonb_to_recordset`. Esquema en `public.staging_tryton_assets` (BD `n8n`). **Fix 2026-08-28:** no existía; los nodos PG `Reset staging`, `Load staging (bulk)`, `Diff assets (batch)` y `Run summary` fallaban con `relation "staging_tryton_assets" does not exist`. Añadida a `sql/init-sync-tables.sql` §5 y aplicada.

| Columna | Notas |
|---------|-------|
| `tryton_asset_id` | Clave (UNIQUE, target de `ON CONFLICT DO NOTHING`) |
| `code` | `asset_tag` en Snipe-IT |
| `internal_code` | Código interno Tryton |
| `name` | Nombre del activo |
| `asset_state` | Estado Tryton (`good`, `bad`, …) — join con `tryton_snipe_status_map.tryton_name` |
| `tryton_model_id` | FK lógico a `tryton_snipe_model_map.tryton_model_id` |
| `tryton_model_name` | Nombre de modelo en Tryton (auditoría) |
| `category_name` | Categoría derivada (auditoría) |

### `tryton_snipe_asset_map` — orquestador v2 (batch)

Mapa persistente Tryton ↔ Snipe-IT. Esquema en `public.tryton_snipe_asset_map` (BD `n8n`). **Fix 2026-08-28:** no existía; `Diff assets (batch)` y `Upsert asset map` fallaban. Añadida a `sql/init-sync-tables.sql` §6 y aplicada.

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

Tabla efímera por ejecución. `DELETE` al inicio y `INSERT` masivo desde `jsonb_to_recordset`. Esquema en `public.staging_titular` (BD `n8n`). **Fix 2026-09-01:** no existía en `sql/init-sync-tables.sql` (solo §1-7); `Reset/Cargar staging titular` y `Contar omitidos` fallaban con `relation "staging_titular" does not exist`. Añadida a `sql/init-sync-tables.sql` §8 y aplicada; `scripts/reset-sync.sh` actualizado para truncarla.

| Columna | Notas |
|---------|-------|
| `snipe_asset_tag` | `asset_tag` en Snipe-IT (code Tryton) |
| `email` | `login@guayas.gob.ec` derivado de `res_user.login` |
| `first_name` | Title-cased desde `party_party.first_name` |
| `last_name` | Title-cased desde `party_party.last_name` |

### `snipe_titular_user_map` — cache email → snipe_user_id

Esquema en `public.snipe_titular_user_map` (BD `n8n`). **Fix 2026-09-01:** faltaba DDL §9; `Upsert user map` fallaba. Añadida a `sql/init-sync-tables.sql` §9.

| Columna | Notas |
|---------|-------|
| `email` | PK — clave para `ON CONFLICT (email) DO UPDATE` |
| `snipe_user_id` | ID en Snipe-IT |
| `updated_at` | `now()` |

### `snipe_titular_map` — titular vigente por activo

Esquema en `public.snipe_titular_map` (BD `n8n`). **Fix 2026-09-01:** faltaba DDL §10; `Upsert titular map`/`Diff titular` fallaban. Añadida a `sql/init-sync-tables.sql` §10.

| Columna | Notas |
|---------|-------|
| `snipe_asset_tag` | PK — clave para `ON CONFLICT (snipe_asset_tag) DO UPDATE` |
| `email` | Email del titular vigente |
| `snipe_user_id` | ID del usuario en Snipe-IT |
| `updated_at` | `now()` |

### `sync_run_summary` — orquestador v2 (batch)

Resumen por ejecución del orquestador. Esquema en `public.sync_run_summary` (BD `n8n`). **Fix 2026-08-28:** no existía; `Run summary` fallaba. Añadida a `sql/init-sync-tables.sql` §7 y aplicada.

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
| `staging_tryton_assets` / `tryton_snipe_asset_map` / `sync_run_summary` no existen en BD `n8n` | Orquestador v2 (batch) fallaba en `Reset staging` con `relation "staging_tryton_assets" does not exist`; DDL faltaba en `sql/init-sync-tables.sql`. > **Fix 2026-08-28:** DDL añadido §5-7 a `sql/init-sync-tables.sql` y aplicado a BD `n8n` (`docker-postgres-1`); spec § Tablas de mapeo y `docs/04` §4.6 sincronizados; `scripts/reset-sync.sh` actualizado para truncar las 3 tablas. |
| Merge `Wait models` `chooseBranch` dead-end | Orquestador v2: Merge recibía por input 1 (`Execute models`) y salía por output 1 no conectado → `Prepare staging payload` nunca recibía datos; además `Prepare staging payload` esperaba `$('Wait models').first().json.result` (item de `Flatten assets` que no existe en esa rama). > **Fix 2026-08-28:** Merge `Wait models` eliminado; `Execute Tryton sync snipeIT models` conecta directo a `Prepare staging payload`; `Prepare staging payload` migrado a `$('Flatten assets').first().json.result`. `Wait categories & statuses` queda pendiente (mismo patrón `chooseBranch`, sólo passthrough). |
| Sub-workflow models lanzado 1 vez por modelo | `Split Out models` + `Execute Workflow` en modo `each`: 597 sub-ejecuciones seriales de ~0.5 s (arranque n8n + queries PG por item) ≈ 331 s en el run 288, ~100% del orquestador; ~4.8 MB de `execution_data` por run. > **Fix 2026-08-28 (batch models):** lote en 1 item al sub (modo once), 1 query `jsonb_to_recordset` para resolver mapas, filtro de no-ops en `Prepare items`, upsert bulk con `ON CONFLICT (tryton_model_id)`; self-heal/log quedan por-item; `saveDataSuccessExecution: none` en el sub. Steady-state: fase models de ~200-300 s a ~1-3 s. |
| `Prepare items` vaciaba salida en steady-state | `Prepare items` filtrado a 0 items dejaba al sub con 0 de salida → `Execute Workflow` sacaba 0 → `Prepare staging payload` no corría y la fase 2 nunca evaluaba assets (observado run 886, 2026-08-31: staging/asset_map/summary vacíos). > **Fix 2026-08-31:** `Prepare items` emite un item `noop` cuando no hay pendientes y `Has work?` lo rutea a `Finish`; el orquestador fija `alwaysOutputData: true` en `Execute models` como red. `Update snipe-it model` con `onError: continueRegularOutput`. |
| `$input.allItems is not a function` en `Build save payload` | Code `runOnceForAllItems` (`Build save payload`, `flows/flujos-dev/Tryton sync snipe-IT models.json:628`) usaba `$input.allItems()` — no existe en n8n (API es `$input.all()`/`$input.first()`/`$input.last()`). Error `TypeError` en `JsTaskRunner.runForAllItems` (n8n 2.36.7). > **Fix 2026-08-31:** cambiado a `$input.all().map(i => i.json)`; re-importar workflow en n8n si se editó en la UI. |
| UI congelada al ejecutar nodo | `Search assets` sin límite (`0, null, null` → 9.5k filas, 7-10 MB `execution_entity.jsonSizeBytes`, runs 288/1053/1054) + `saveDataSuccessExecution: all` → navegador colgado al renderizar `Flatten assets`/`Prepare staging payload`/`Model list` y payload `JSON.stringify(rows)`. > **Fix 2026-08-31:** inicial `0,100,null` + `settings.saveDataSuccessExecution: none / …` en 6 workflows + `UPDATE workflow_entity`; `100` solo daba 23/558 modelos → restaurado a `0,null,null` para 558/597 manteniendo `saveDataSuccessExecution: none` + `Tag for save` a `Set` (vs `Code`); limpiar `execution_entity` pesadas. |
| `Detectar cambios de titular` con 8000+ items congela UI / llena `execution_entity` | `Tryton sync titular-activo` (`yjyUYjVEaZ9UniSs`) sin `saveDataSuccessExecution: none` guardaba ~10 nodos × 8000 items (~10-30 MB/run) en `execution_entity`; abrir la ejecución congelaba el navegador (mismo síntoma del fix 2026-08-31 para 6 workflows, pero este workflow se creó el 2026-09-01 sin heredar los settings). > **Fix 2026-09-02:** `settings` alineados a `status`/`models`/`ingest` (`saveDataSuccessExecution: none` / `saveDataErrorExecution: all` / `saveExecutionProgress: false` / `executionTimeout: 3600`) vía `UPDATE workflow_entity SET settings WHERE id='yjyUYjVEaZ9UniSs'` + `docker compose restart n8n`; snapshot sincronizado (`docs/04` §4.6). |
| 429 `Try spacing your requests out` en Snipe-IT models | `Create/Update snipe-it model` sin `batching` → `429` en `integration_sync_log` (150/582 run 1101; 219/291 con `5/1000`) por Snipe-IT rate limit (~300/min → 429). > **Fix 2026-08-31:** `options.batching.batch {batchSize:1, batchInterval:1200}` en ambos HTTP (`flows/flujos-dev/Tryton sync snipe-IT models.json:287,376`) + restart n8n; 558 modelos en ~670s (1/1.2s) sin 429. |
| `Find model in Snipe` `search=undefined` (self-heal roto) | `Find model in Snipe` usaba `$json.asset_model_name` tras `Create` con `fullResponse: true` → el item es `{body,statusCode}` sin ese campo → `search=undefined` → `{"total":0}`; duplicados Tryton (mismo nombre ya sincronizado) nunca se recuperan → 40/597 sin mapeo (`tryton_snipe_model_map` 557/597). > **Fix 2026-09-01:** cambiado a `$('Prepare items').item.json.asset_model_name` en `flows/flujos-dev/Tryton sync snipe-IT models.json:476` + `UPDATE workflow_entity JODxuGjfCJ2wDobA` + backfill de 40 al `snipe_model_id` canónico; ver § Tryton sync snipe-IT models. |
| Custom field `_snipeit_internal_code_2` inexistente → 0 assets, `success` engañoso | `snipeit.custom_fields` solo 1 fila (MAC, id 1) y `custom_fieldsets` solo id 1; faltaba custom field `internal_code` (id 2 → `_snipeit_internal_code_2`) y fieldset id 2 (`Activos Tryton`, referenciado por `models.fieldset_id=2`). Orquestador 1265 / ingest 1266: 9565 total / 8132 to_create / 6314 api_errors / 0 en `tryton_snipe_asset_map` y `snipeit.assets` 0; todos los POST `/hardware` con `200 {"status":"error","messages":{"_snipeit_internal_code_2":[...]}}`. > **Fix 2026-09-01:** añadidos en `flows/flujos-dev/Tryton sync snipe-IT assets ingest (batch).json` — guarda pre-flight `Check custom field internal_code` (GET `/api/v1/fields`) → `Has internal_code field?` (db_column `_snipeit_internal_code_2`) → `Fail: missing custom field` (Stop and Error, ~1 s, mensaje `ejecute ./scripts/snipe-it_custom_fields.sh`) y guarda post-loop `Has API errors?` (api_errors>0) → `Fail: ingest had API errors` para que la ejecución quede en `error`; script idempotente `scripts/snipe-it_custom_fields.sh` + `docs/manual-implementacion.md`; re-export snapshot (21 nodos con Loop/Finish); re-ejecutar orquestador tras provisioning. |
| Activos huérfanos tras cancelación → 383 en Snipe-IT sin map | Cancelación a mitad de loop (upsert no ejecutado): `snipeit.assets` 5644 vs `tryton_snipe_asset_map` 5261 (383 `asset_tag` en Snipe sin map; `comm` 383/0). Re-ejecución sin self-heal reintentaba `create` → `asset_tag must be unique` perpetuo. > **Fix 2026-09-01 (self-heal assets):** añadidos en ingest `Find asset in Snipe` (GET `/api/v1/hardware?asset_tag=X`, `=`) → `Recover asset` (match exacto en `body.rows`, normaliza `body.payload`) → `Recovered asset?` → `Upsert asset map` en rama `Saved? false`; `Log error` solo si no existe. La re-ejecución corrige los 383 y crea los ~3.9k restantes. Snapshot 21→24 nodos; sin duplicados de `code` en staging verificado (0). |
| `Node execution failed` — task runner disconnect (OOM) | `Tryton sync snipe-IT assets ingest (batch)` con 9.5k payload + 24 nodos + self-heal por item excede heap del JS runner interno (`--max-old-space-size` por defecto). Ejecuciones 1316/1317 (17:24) abortan a los ~6 min con `InternalTaskRunnerDisconnectAnalyzer` / `TaskBrokerWsServer.removeConnection`. > **Fix 2026-09-01:** `envs/n8n.env:5` `N8N_RUNNERS_MAX_OLD_SPACE_SIZE=4096` + `docker compose up -d n8n` (heap 4 GiB). Alternativa externa: descomentar `n8n-runner` en `docker-compose.yml` (`N8N_RUNNERS_ENABLED=true`, `N8N_RUNNERS_MODE=external`). Ver `docs/04` §4.5 y `docs/manual-implementacion.md` §7. |
| 429 `Try spacing your requests out` en Snipe-IT assets ingest | `Create/Update snipe-IT asset (batch)` sin `batching` → `429` en `access.log` (219 en ventana 18:13-18:43, run 1319: 112 faltantes sin log por `Log error` silencioso). > **Fix 2026-09-01:** `options.batching.batch {batchSize:1, batchInterval:550}` + `retryOnFail:true, maxTries:4, waitBetweenTries:3000` en ambos HTTP (`flows/flujos-dev/Tryton sync snipe-IT assets ingest (batch).json:187,213`) + `Find asset in Snipe` con retry 3×2s; `Recover asset` propaga `tryton_id/operation/response_*` y `Log error` lee `$json.*` (no `$('Batch changes').item` cruzado). Ver `docs/04` §4.5. |
| `Execute login` huérfano + `SNIPE_TOKEN` vs `SNIPEIT_TOKEN` + `TRYTON_HOST` vs `TRYTON_URL` en titular-activo | `Tryton sync titular-activo (v1)` `Execute login` → `RuVLU1TOMoOxqVE3` (borrado) → falla primer nodo; `Aplicar` usaba `$env.SNIPE_TOKEN` inexistente (`SNIPEIT_TOKEN` en `envs/n8n.env`) → 401 masivo (200/0/200×401); `Leer activos` usaba `$env.TRYTON_HOST` vs `TRYTON_URL` del resto. > **Fix 2026-09-01:** repuntado `Execute login` → `Cnq2yvzVCRTKFld5` y `TOKEN = $env.SNIPEIT_TOKEN \|\| $env.SNIPE_TOKEN` + `($env.TRYTON_URL \|\| $env.TRYTON_HOST)` en `Leer activos`; `retryOnFail 3×3s` y retry 2×1.5s/3s en `api()`. Ver `flows/flujos-dev/Tryton sync titular-activo.json:45,89,228` y `docs/04` §4.6. |
| `staging_titular`/`snipe_titular_map`/`snipe_titular_user_map` no existen en BD `n8n` | Titular-activo fallaba en `Reset/Cargar staging titular` con `relation "staging_titular" does not exist`; `Diff titular` y upserts también; DDL faltaba en `sql/init-sync-tables.sql` (solo §1-7). > **Fix 2026-09-01:** DDL añadido §8-10 a `sql/init-sync-tables.sql` y aplicado a BD `n8n` (`docker-postgres-1`); `scripts/reset-sync.sh` actualizado para truncar las 3 tablas; spec § Tablas de mapeo y `docs/04` §4.6 sincronizados. |
| Titular-activo tragaba errores (sin logging) | `Aplicar en Snipe-IT` capturaba errores en `errs[]` solo a `staticData.lastRun` (no persiste en manual/early-fail; workflow terminaba en `success` con 0 aplicados aunque 200 errores). Sin `Log error` a `integration_sync_log`; omitidos (staging sin `asset_map`) invisibles. > **Fix 2026-09-01:** `Aplicar en Snipe-IT` retorna `{status:'ok'\|'error', error_message, response_status}` por fila; nuevo IF `¿Aplicado?` → `Upsert *` (ok) / `Log error titular` (error, `integration_sync_log` `titular_checkout`); nuevos `Contar omitidos` + `Resumen titular` → `Log resumen titular` (`run_summary` `entity='titular'` siempre con `{cambios, aplicados, errores, omitidos, usuarios_nuevos}`). `integration_sync_log` es ahora auditoría completa del titular. Snapshot 15→19 nodos (`flows/flujos-dev/Tryton sync titular-activo.json`). |
| No-revocación de titular | Patrón solo asigna/reasigna; si `current_owner=null` o empleado sale, el activo queda checkout al titular anterior en Snipe-IT. > **Decisión 2026-09-01:** comportamiento intencional por ahora (evita des-asignaciones masivas ante lag ERP). Documentado como limitación pendiente; cambiar aquí cuando haya política de `checkin` automático. |
| `Task execution timed out after 300 seconds` en titular-activo | `Aplicar en Snipe-IT` (Code `runOnceForAllItems`, `flows/flujos-dev/Tryton sync titular-activo.json:228`) ejecutaba `ensureUser` + `checkout` en bucle secuencial con `helpers.httpRequest` + `sleep(1500)` dentro de una sola tarea del JS task runner (límite `N8N_RUNNERS_TASK_TIMEOUT=300` por defecto, n8n 2.36.7 `TaskBroker.handleTaskTimeout`). Con N filas el `for...await` superaba 300 s → timeout. > **Fix 2026-09-02:** refactor de `Aplicar en Snipe-IT` de Code a nodos nativos (`¿Usuario existente?` → `Buscar usuario` `GET /users?email=` → `¿Encontrado?` → `Preparar usuario nuevo` → `Crear usuario` `POST /users` → `Crear usuario (alt)` (username con sufijo) → `Antes de checkout` → `Checkout` `POST /hardware/{id}/checkout` → `Checkin` `POST /checkin` → `Checkout reintento`, todos `httpBearerAuth` `Adhjdtilu8D9eQs8`, `retryOnFail 3×2s`/`onError: continueErrorOutput/continueRegularOutput`, `batching 20/500ms`, `timeout 30s`); corre en proceso principal sin límite del runner. Snapshot 19→37 nodos. Ver `docs/04` §4.6. |
| `Buscar usuario por email` per-item colapsa Snipe-IT (50 min solo en ese nodo) | `Buscar usuario por email en Snipe-IT` (`GET /api/v1/users?email=&limit=1`, `batching 20/500ms`, `retryOnFail 3×2s`, `onError: continueErrorOutput`) con `Detectar cambios de titular` 8,991 items y `snipe_titular_user_map` vacío → 8,991 GETs, **96 éxito y 8,895 error** en ejecución 1487 (`timeout of 30000ms` 8,541, resto `ETIMEDOUT`/`ECONNRESET`/`EAI_AGAIN`), `executionTime` 2,991,056 ms (~50 min), Snipe-IT 804% CPU y DNS `EAI_AGAIN`; cada corrida repetía el costo (nunca llegaba a `Guardar usuario en mapa (BD)`). 74 usuarios en Snipe vs 698 emails distintos; `email=''` → primer usuario (falso match); y 1 creación por *asset* (no por email) → ~13 intentos duplicados por email. > **Fix 2026-09-03:** precarga bulk antes del diff: `Precargar usuarios de Snipe-IT` (1 GET `/api/v1/users?limit=500`) → `Guardar mapa de usuarios (bulk)` (`jsonb_to_recordset($1) LOWER(email)`) → `Calcular usuarios faltantes` (`DISTINCT ON LOWER(email)` no en mapa) → `¿Hay usuarios faltantes?` → `Extraer usuarios faltantes` (1 por email) → `Crear usuario en Snipe-IT`/`Reintentar alt` → `Guardar usuario creado en mapa (BD)` + `Usuarios listos` (colapsa M→1); rama false directa a `Contar activos sin mapeo`. `Detectar cambios` con guarda `s.email<>''` y join `LOWER(s.email)`. `¿Titular ya mapeado en BD?` sin HTTP: `true`→`Usar usuario del mapa`, `false`→`Marcar usuario no disponible`→`Consolidar resultados`. Eliminados `Buscar usuario por email en Snipe-IT`, `¿Usuario existe en Snipe-IT?`, `Usar usuario existente de Snipe-IT`. Snapshot 37→45 nodos, `UPDATE workflow_entity yjyUYjVEaZ9UniSs` + `docker compose restart n8n`; spec y `docs/04` §4.6 sincronizados. | |
