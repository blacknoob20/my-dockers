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
| Tryton sync snipe-IT assets ingest (batch) | Sub-workflow de negocio | `flows/flujos-dev/Tryton sync snipe-IT assets ingest (batch).json` | `Asse2tIngestSub01` |
| Tryton sync snipe-IT assets orchestrator v2 | Orquestador (batch) | `flows/flujos-dev/Tryton sync snipe-IT assets orchestrator v2 (batch).json` | `3hh7DBsrq8A1rIQg` |

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

### Tryton sync snipe-IT assets ingest (batch)

- **Archivo:** `flows/flujos-dev/Tryton sync snipe-IT assets ingest (batch).json` (ID `Asse2tIngestSub01`, inactivo)
- **Trigger:** Execute Workflow Trigger (`Tryton sync snipe-IT assets orchestrator`, `inputSource: passthrough`)
- **Entrada:** `{ "payload": "<json-array-string>", "total": 100 }` desde `Prepare staging payload` del orquestador (`payload = JSON.stringify(rows)` donde cada row es `{tryton_asset_id, code, internal_code, name, asset_state, tryton_model_id, tryton_model_name, category_name}`)
- **Invocado por:** orquestador v2 vía `Execute ingest (batch)` (`waitForSubWorkflow: true`)
- **Credenciales:** `postgres` id `qJJfZl7PuKahcYb0`, `httpBearerAuth` id `Adhjdtilu8D9eQs8` (Bearer Snipe-IT)

#### Flujo

```
Tryton sync snipe-IT assets orchestrator ({payload, total})
      ↓
Reset staging (DELETE FROM staging_tryton_assets;)
      ↓
Load staging (bulk) (INSERT INTO staging_tryton_assets ... SELECT DISTINCT ON (tryton_asset_id) ... FROM jsonb_to_recordset($1) ON CONFLICT DO NOTHING — $1 = $('Tryton sync snipe-IT assets orchestrator').first().json.payload)
      ↓
Diff assets (batch) (SELECT ... FROM staging_tryton_assets s JOIN tryton_snipe_model_map m ON m.tryton_model_id = s.tryton_model_id AND m.snipe_model_id IS NOT NULL JOIN tryton_snipe_status_map st ON st.tryton_name = s.asset_state LEFT JOIN tryton_snipe_asset_map am ON am.tryton_asset_id = s.tryton_asset_id WHERE IS DISTINCT — calcula action='create'|'update')
      ↓
Any changes? (IF $json.action notEmpty)
  ├─ true  → Batch changes (splitInBatches, batch size 1)
  │              ↓ (done)           ↓ (each)
  │           Run summary        Create or update? (IF $json.action == 'create')
  │                                 ├─ true  → Create snipe-IT asset (batch) (POST /api/v1/hardware {name, asset_tag, status_id, model_id, _snipeit_internal_code_2})
  │                                 └─ false → Update snipe-IT asset (batch) (PATCH /api/v1/hardware/{snipe_asset_id} {name, asset_tag, status_id, model_id, _snipeit_internal_code_2})
  │                                              ↓
  │                                           Saved? (IF body.status == "success")
  │                                            ├─ true  → Upsert asset map (INSERT INTO tryton_snipe_asset_map ... ON CONFLICT (tryton_asset_id) DO UPDATE)
  │                                            └─ false → Log error (batch) (INSERT INTO integration_sync_log {execution_id=$execution.id, workflow_name=$workflow.name, tryton_id, operation=action, response_status, response_body, error_message})
  │                                                         ↓
  │                                                      Batch changes (loop-back)
  └─ false → Run summary (INSERT INTO sync_run_summary (run_id, total_tryton, to_create, to_update, unchanged, missing_model, deleted_in_tryton, api_errors) SELECT ... FROM staging ... RETURNING *, executeOnce)
```

- `Create/Update snipe-IT asset (batch)`: `onError: continueRegularOutput` + `fullResponse: true` — errores HTTP no rompen el loop, pasan a `Saved?` → `Log error`.
- `Upsert asset map` / `Log error (batch)`: `onError: continueRegularOutput`, `alwaysOutputData: true` — el loop continúa aunque el upsert/log falle.
- `Run summary`: `executeOnce: true` — se ejecuta una sola vez aunque `Diff assets` devuelva múltiples filas; cuenta `api_errors` con `COUNT(*) FROM integration_sync_log WHERE execution_id = $execution.id` (mismo `execution_id` del sub).
- **Nota `workflow_name`:** `Log error (batch)` registra `$workflow.name` del **sub-workflow** (no del orquestador). Es el comportamiento elegido tras el refactor; ver nota en orquestador v2.

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
- **Limitaciones generales:** `tryton_id` y `snipe_id` en `0` para categorías/estados; sin reconciliación de activos existentes; `SNIPE_HOST` debe ser `http://snipe-it:80` dentro de la red Docker (no `localhost`).

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
| 429 `Try spacing your requests out` en Snipe-IT models | `Create/Update snipe-it model` sin `batching` → `429` en `integration_sync_log` (150/582 run 1101; 219/291 con `5/1000`) por Snipe-IT rate limit (~300/min → 429). > **Fix 2026-08-31:** `options.batching.batch {batchSize:1, batchInterval:1200}` en ambos HTTP (`flows/flujos-dev/Tryton sync snipe-IT models.json:287,376`) + restart n8n; 558 modelos en ~670s (1/1.2s) sin 429. |
| `Find model in Snipe` `search=undefined` (self-heal roto) | `Find model in Snipe` usaba `$json.asset_model_name` tras `Create` con `fullResponse: true` → el item es `{body,statusCode}` sin ese campo → `search=undefined` → `{"total":0}`; duplicados Tryton (mismo nombre ya sincronizado) nunca se recuperan → 40/597 sin mapeo (`tryton_snipe_model_map` 557/597). > **Fix 2026-09-01:** cambiado a `$('Prepare items').item.json.asset_model_name` en `flows/flujos-dev/Tryton sync snipe-IT models.json:476` + `UPDATE workflow_entity JODxuGjfCJ2wDobA` + backfill de 40 al `snipe_model_id` canónico; ver § Tryton sync snipe-IT models. |
