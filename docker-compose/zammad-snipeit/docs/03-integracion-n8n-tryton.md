# 3. Integración Tryton → n8n

## Objetivo

Construir workflows en n8n que consumen la API JSON-RPC de Tryton usando un sub-workflow de autenticación reutilizable con caché de sesión, validación y reintentos.

---

## 3.1 Arquitectura

La integración se compone de un sub-workflow de autenticación y workflows de negocio:

| Workflow | Rol |
|----------|-----|
| **Tryton login** | Sub-workflow de autenticación. Se ejecuta desde otros workflows. Cachea la sesión, la valida, y hace re-login automático si expiró. |
| **Workflows de negocio** | Workflows que consumen datos de Tryton. Usan un nodo `Execute Workflow` apuntando a "Tryton login" para obtener el header de autorización. |

Los exports de los workflows viven en `flows/`:

| Archivo | Workflow |
|---------|----------|
| `flows/Tryton login.json` | Tryton login |
| `flows/Tryton sync categories.json` | Tryton sync categories |
| `flows/Tryton sync models.json` | Tryton sync models |
| `flows/Tryton sync statuses.json` | Tryton sync statuses |
| `flows/Tryton sync assets.json` | Tryton sync assets (principal) |

> **Nota:** los archivos en `flows/` son snapshots. Al modificar un workflow en n8n, hay que re-exportarlo para mantenerlos al día.

---

## 3.2 Sub-workflow "Tryton login"

Archivo: `flows/Tryton login.json`

### Trigger

| Config | Valor |
|--------|-------|
| Node type | `Execute Workflow Trigger` |
| Nombre del nodo | `Executed by Tryton Sync Assets` |
| Input | `ok` (boolean) — el valor no se usa |

### Flujo

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
             Try again? (IF: ¿error JSON-RPC?)
              ├── SÍ → Some session? (reintento sin contador)
              └── NO → Save Authentication ──→ Edit Fields ──→ Finish
```

Ruta de error de transporte (HTTP/red):

```
Tryton login (error de red)
      ↓
Retries 3 times (Code: contador en staticData, máx 3)
      ↓
Is not alive? (IF)
 ├── SÍ → Send a message (Gmail a reguerre@espol.edu.ec)
 │            ↓
 │        Stop and Error
 └── NO → Tryton login (reintento)
```

### Nodos

| Nodo | Tipo | Función |
|------|------|---------|
| `Executed by Tryton Sync Assets` | Execute Workflow Trigger | Recibe `{ ok }` |
| `Read session` | Code | Lee `$getWorkflowStaticData('global').tryton` |
| `Some session?` | IF | `$json.some_session === true` |
| `Testing session` | HTTP Request | `model.res.user.get_preferences(false, {})` con Auth header |
| `Is working?` | IF | `$json.error` vacío? |
| `Tryton login` | HTTP Request | `POST common.db.login` con credenciales |
| `Try again?` | IF | `($json.error \|\| []).length > 0` |
| `Retries 3 times` | Code | Contador de reintentos en staticData (máx 3) |
| `Is not alive?` | IF | `$json.shouldStop === true` (3 intentos fallidos) |
| `Send a message` | Gmail | Alerta: "Tryton Unavalible — endpoint caído después de 3 intentos" |
| `Stop and Error` | Stop and Error | Termina la ejecución con error |
| `Save Authentication` | Code | Construye `Session <base64(svc_n8n:uid:session)>` y lo guarda en staticData |
| `Edit Fields` | Set | Output: `{ authorization }` (toma del path que corresponda) |
| `Finish` | NoOp | Fin del flujo |

### Output

```json
{
  "authorization": "Session c3ZjX244bjoyMTYwOjgxZmNiMDVl..."
}
```

### Código clave

**Save Authentication:**
```javascript
const [uid, session] = $json.result;
const auth = Buffer
  .from(`svc_n8n:${uid}:${session}`)
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

### Comportamiento de errores (comportamiento real)

| Situación | Comportamiento |
|-----------|---------------|
| Sesión cacheada vigente | Se reusa sin hacer login |
| Sesión expirada | Re-login automático (1 request adicional) |
| Error JSON-RPC (HTTP 200 con `error` en el body) | Vuelve a `Some session?` y reintenta **sin** pasar por el contador |
| Error de transporte HTTP (red caída) | Pasa por `Retries 3 times` |
| 3 reintentos fallidos | Alerta por Gmail a `reguerre@espol.edu.ec` y `Stop and Error` |

> **Notas:** no existe nodo de espera de 1 segundo entre reintentos. El contador no se reinicia tras un login exitoso (solo al llegar al máximo). La sesión vive en `staticData` global.

---

## 3.3 Cómo consumir el login desde otros workflows

En cualquier workflow que necesite datos de Tryton:

1. Agregar un nodo **Execute Workflow**
2. Apuntar al workflow "Tryton login"
3. El output del nodo contiene `authorization` con el header listo

```
[Trigger] → Execute Workflow ("Tryton login")
                ↓
           HTTP Request (Tryton API con auth)
                ↓
           [Resto del flujo]
```

**Headers del HTTP Request:**
```
Authorization: {{ $json.authorization }}
```

---

## 3.4 Variables de entorno

| Variable | Valor (lab) | Valor (prod) |
|----------|-------------|--------------|
| `TRYTON_HOST` | `http://192.168.56.102:8000` | `https://financieroprueba.guayas.gob.ec` |
| `TRYTON_LOGIN_USER` | `svc_n8n` | `svc_n8n` |
| `TRYTON_LOGIN_PASS` | (secreto) | (secreto) |
| `SNIPE_HOST` | `http://snipe-it:80` | `http://snipe-it:80` |

> **Nota:** el nombre de base de datos (`dbegoblocal`) está hardcodeado en los nodos HTTP. En producción habría que parametrizarlo (por ejemplo `TRYTON_DB`).
>
> En producción, el rate limit de HAProxy puede bloquear requests frecuentes. Mantener mínimo 3 segundos entre requests.

---

## 3.5 Referencia rápida de endpoints

| Endpoint | Uso |
|----------|-----|
| `POST /api/v1/categories` | Crear categoría |
| `POST /api/v1/models` | Crear modelo |
| `PATCH /api/v1/models/:id` | Actualizar modelo (nombre) |
| `POST /api/v1/statuslabels` | Crear status label |
| `POST /api/v1/hardware` | Crear activo |

Detalles de cada workflow de negocio en `docs/04-workflows-sincronizacion.md` y en el spec `.ai/specs/tryton-activos.md`.
