# Spec: Enriquecimiento de tickets Zammad con activos Snipe-IT (bajo demanda)

## Contexto

No existe sincronización continua Snipe-IT → Zammad (generaría duplicación:
el titular de un activo puede cambiar entre la sincronización y la creación
del ticket). En su lugar, al crear un ticket Zammad consulta el estado
**actual** en Snipe-IT y lo escribe en el ticket (fuente de verdad del
inventario en el momento correcto).

```
Nuevo Ticket → Webhook → n8n → Snipe-IT (live) → PUT ticket → Zammad
```

Ejemplo: ayer el usuario tenía Laptop HP + Monitor LG; hoy el técnico la
cambió por Laptop Dell. El ticket creado hoy refleja Laptop Dell + Monitor LG.

| Sistema    | Responsabilidad                           |
|------------|-------------------------------------------|
| **Tryton** | Fuente de verdad institucional            |
| **Snipe-IT** | Inventario y asignación actual de activos |
| **n8n**    | Integración y orquestación                |
| **Zammad** | Gestión del ticket y atención al usuario  |

---

## Arquitectura

- **Archivo:** `flows/zammad/Zammad enrich ticket assets.json`
- **Trigger:** Webhook `POST /webhook/zammad-ticket-created` (nodo
  `Zammad ticket created`, `responseMode: responseNode`).
- **Disparo en Zammad:** Trigger `Action is created` (Selective) → acción
  `Notification > Webhook`. Solo tickets nuevos: el `PUT` posterior del flujo
  es un `update` y **no** re-dispara el trigger (anti-loop por diseño).
- **Credenciales:** `postgres` → `pg_n8n`, `httpBearerAuth` → `bearer_snipe`
  (Snipe-IT), `httpHeaderAuth` → `zammad_header` (Zammad, header
  `Authorization: Token token=...`).
- **Variables:** `SNIPE_HOST` (`http://snipe-it:80` en red Docker),
  `ZAMMAD_HOST` (`http://zammad-nginx:8080` en red Docker). Nunca `localhost`
  desde dentro del stack (ver gotcha SNIPE_HOST en spec Tryton).
- **Auditoría:** solo `integration_sync_log`
  (`source_system='zammad'`, `entity='ticket'`, `operation='enrich_assets'`).
  Sin tabla nueva, sin cambios en `sql/init-sync-tables.sql` ni en
  `scripts/reset-sync.sh`. `Log Error` NUNCA guarda el objeto de error crudo
  (contiene `options.headers.Authorization`): solo `{message, code, status}`.
  > **Fix 2026-09-10:** el error `EAI_AGAIN` serializó el header con el token
  en `response_body` (fila 19, redactada por SQL); `Log Error` ahora
  sanitiza antes de insertar.
- **Settings:** `saveDataSuccessExecution: none` /
  `saveDataErrorExecution: all` / `saveExecutionProgress: false` /
  `executionTimeout: 3600` (alineado al resto de flujos).

### Flujo

```
Zammad ticket created (webhook)
      ↓
Extract Ticket (Set: ticket_id / ticket_number / customer_email)
      ↓
Has Email? (IF customer_email notEmpty)
  ├─ Sí → Find Snipe User (GET /api/v1/users?email=…&limit=10)
  │           ↓
  │        Match Snipe User (Code: match exacto LOWER; duplicados → id menor)
  │           ↓
  │        Has User? (IF snipe_user_id notEmpty)
  │         ├─ Sí → Get Assigned Assets
  │         │         (GET /api/v1/hardware?assigned_to={id}&assigned_type=App\Models\User&limit=100)
  │         │           ↓
  │         │        Build Enrichment (Code: count/tags/summary/nota)
  │         └─ No → Build Empty (no user) (Code: nota según causa)
  └─ No → Build Empty (no email) (Set estático)
      ↓ (3 ramas convergen: mismo contrato)
Update Zammad Ticket (PUT /api/v1/tickets/{id}: customs + article note internal)
      ↓
Ticket Updated? (IF body.id notEmpty)
  ├─ Sí → Log Success (INSERT … RETURNING 'ok')
  └─ No → Log Error (INSERT … RETURNING 'error')
      ↓
Respond (JSON {ok, ticket_id, ticket_number, log_status})
```

### Contrato de enriquecimiento

| Campo Zammad         | Tipo     | Origen |
|----------------------|----------|--------|
| `snipe_asset_count`  | integer  | `rows.length` de `/hardware` |
| `snipe_asset_tags`   | textarea | `asset_tag` unidos por `, ` |
| `snipe_asset_summary`| textarea | líneas `- {tag} — {modelo} ({estado}) S/N {serial}` |
| artículo             | note     | `type: note`, `internal: true`, `sender: Agent`, `content_type: text/plain` |

Provisionados una sola vez por instancia con
`scripts/zammad-ticket-objects.sh` (API Object Manager + migraciones +
reinicio obligatorio de workers). Ver `docs/05-integracion-zammad-snipeit.md`.

### Casos

| Caso | Comportamiento |
|------|----------------|
| Usuario con N activos | Customs con N/tags/resumen + nota interna con el detalle |
| Usuario sin activos | `0` / vacíos + nota "Snipe-IT no reporta activos asignados…" |
| Email sin match en Snipe-IT | `0` / vacíos + nota "Snipe-IT no tiene usuario con email …" |
| Webhook sin email | `0` / vacíos + nota "Webhook sin email de cliente…" |
| Fallo red/API Snipe-IT | Degrada a nota de error (no tumba la ejecución); si el `PUT` falla, `Log Error` + `ok: false` al webhook (Zammad reintenta hasta 4 veces) |
| Email duplicado en Snipe-IT | Gana el id menor (mismo criterio que `Bulk Save Users`, fix 2026-09-03) |
| >100 activos por usuario | Truncado a 100 (`limit=100`); documentar si aparece el caso |

### Reglas de expresiones (gotchas heredados)

- El nodo webhook de n8n envuelve el payload HTTP en `$json.body`
  (`{headers, params, query, body, webhookUrl}`): `Extract Ticket` debe leer
  `$json.body?.ticket_id` (con fallback a `$json.ticket_id` por si el item
  llega sin envolver). > **Fix 2026-09-10:** las expresiones leían solo
  `$json.ticket?.id ?? $json.ticket_id`; el smoke test llegaba con body
  correcto pero `Extract` salía `{ticket_id: 0, customer_email: ""}`, el flujo
  tomaba la rama "sin email" y el `PUT` iba a `/tickets/0` (verificado en
  `execution_data` exec 1833 + `integration_sync_log` ids 15-16).
- Todo nodo HTTP `POST/PUT/PATCH` debe llevar `"sendBody": true`: sin esa
  llave n8n ignora `specifyBody/jsonBody` y envía cuerpo vacío (Zammad
  responde 200 sin cambios → `ok:true` engañoso). > **Fix 2026-09-10:**
  `Update Zammad Ticket` era el único POST/PUT/PATCH del repo sin `sendBody`;
  Rails mostraba `Parameters: {"id" => "3"}` pese al 200. Verificado por
  barrido de `flows/*/*.json`.
- Nunca referenciar `$('Nodo')` de una rama no ejecutada: `Build Empty (no email)`
  es `Set` estático y `Build Empty (no user)` solo lee `Match Snipe User`
  (siempre ejecutado en su rama).
- `assigned_type` va URL-encodeado (`App%5CModels%5CUser`) para no pelear con
  el escapado JSON/expresiones.
- `Ticket Updated?` lee `$json.body?.id` (Zammad devuelve el ticket directo,
  sin wrapper `{status}` como Snipe-IT).

---

## Usuarios de servicio y tokens

| Usuario | Email | Rol | Token | Uso |
|---------|-------|-----|-------|-----|
| `svc-n8n` | `svc-n8n@guayas.gob.ec` | Agente (RW en los grupos) | `ZAMMAD_TOKEN` (nivel Agent) | Runtime del webhook |
| `svc-zammad-prov` | `svc-zammad-prov@guayas.gob.ec` | Administrar | `ZAMMAD_TOKEN_PROV` (nivel Admin) | Solo `zammad-ticket-objects.sh`, una vez; luego desactivar/archivar |

Header API Zammad: `Authorization: Token token=<TOKEN>`.

---

## Errores conocidos

| Caso | Comportamiento actual |
|------|----------------------|
| `ZAMMAD_HOST=localhost` dentro del stack | Igual que el gotcha `SNIPE_HOST`: usar `http://zammad-nginx:8080` |
| Webhook Zammad inalcanzable | Zammad reintenta hasta 4 veces con la prioridad de los triggers de email |
| `PUT` con campo custom inexistente | El flujo falla en `Ticket Updated?` → `Log Error`; ejecutar primero `zammad-ticket-objects.sh --check` |
| Credencial `httpHeaderAuth` con sentinela `ZAMMAD_HEADER_PENDIENTE` | Snapshot sin remapear: crear la credencial Header Auth en cada n8n, anotar IDs en `envs/n8n-creds.{casa,trabajo}.json` (locales, ignorados) y re-ejecutar `n8n-remap.sh` v1.3.0+ |
| Comentario inline en `envs/n8n.env` pega el valor con `cut -d= -f2-` | `ZAMMAD_TOKEN=abc # comentario` → el script leía `abc # comentario` → 401 `Can't find User for Token`. > **Fix 2026-09-10:** `zammad-ticket-objects.sh` (y cualquier lector) usa `cut -d' ' -f1` tras el `cut -d=`; compose sí recorta el comentario (verificado len 64 en contenedor). Comparación por hash md5 contra `tokens` confirmó el match sin exponer secretos. |
| Crear ticket con customer inexistente | `POST /api/v1/tickets` con email no registrado → 422 `No lookup value found for 'customer'`. > **Fix 2026-09-10:** en el test se usa un customer existente (`svc-n8n@guayas.gob.ec`); en el flujo real el customer siempre existe (es quien crea el ticket). |
| `PUT` falla con `{"code":"ERR_INVALID_HTTP_TOKEN"}` | Credencial Header Auth mal formada. Caso real 2026-09-10: campo **Name** = `Zammad ticket auth` (los espacios hacen inválido el header name y Node lanza antes de enviar) y **Value** = `=<token>` (sin prefijo `Token token=`; tras corregir el Name habría dado 401). > **Fix 2026-09-10:** Name `Authorization`, Value `Token token=<token>`; no es 401/403. Diagnóstico por hash contra `envs/n8n.env` sin exponer secretos (`n8n export:credentials --decrypted`). |
