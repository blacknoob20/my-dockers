# 5. Integración Zammad ↔ Snipe-IT (enriquecimiento bajo demanda)

Spec canónico: `.ai/specs/zammad-tickets.md`. Este documento es la guía
operativa paso a paso. Complementa `04-workflows-sincronizacion.md`
(Tryton → Snipe-IT) y `manual-implementacion.md` §2.3/§8.

**Principio:** no hay sync Snipe-IT → Zammad. Al crear un ticket, Zammad avisa
por webhook, n8n consulta el estado **actual** en Snipe-IT y escribe el
resultado en el ticket. Ver tabla de responsabilidades en el spec.

---

## 5.1 Prerrequisitos

- Stack levantado (`docker compose up -d`) con Zammad (`http://localhost:8000`),
  Snipe-IT (`http://localhost:8080`) y n8n (`http://localhost:5678`).
- Flujo Tryton → Snipe-IT corriendo (los activos y titulares ya existen en Snipe-IT).
- `jq` instalado (los scripts lo exigen con mensaje claro si falta).

## 5.2 Primera vez en Zammad (wizard)

1. En **Notificación por correo electrónico** pulsar **Saltar** (el flujo no usa
   email; se configura después en Admin → Sistema → Correo si hace falta).
2. **Sistema**: nombre visible (p. ej. `Soporte EGOB`) y nombre corto.
3. **Diseño**: opcional, se puede saltar.
4. **Cuenta de administrador**: crearla (email + contraseña). Es el login para
   todo lo que sigue.

## 5.3 Usuarios de servicio y tokens

Crear dos usuarios (Admin → Usuarios → Nuevo). Campos opcionales
(web, teléfono, organización, dirección, VIP, nota) se dejan vacíos.

| # | Nombre / Apellido | Email | Contraseña | Roles |
|---|-------------------|-------|------------|-------|
| 1 | `svc` / `n8n` | `svc-n8n@guayas.gob.ec` | fuerte (anotarla) | ☑ **Agente** (RW en los grupos de tickets) |
| 2 | `svc` / `zammad-prov` | `svc-zammad-prov@guayas.gob.ec` | fuerte (anotarla) | ☑ **Administrar** |

Tokens (con cada usuario logueado: avatar abajo-izquierda → **Token Access** →
New Token; el valor **solo se muestra una vez**):

| Token | Usuario | Nivel | Variable | Uso |
|-------|---------|-------|----------|-----|
| `n8n-enrich` | `svc-n8n` | **Agent** | `ZAMMAD_TOKEN` | Runtime del webhook (`PUT /tickets/{id}` + nota) |
| `n8n-prov` | `svc-zammad-prov` | **Admin** | `ZAMMAD_TOKEN_PROV` | Solo el script de objetos, una vez |

Verificación:

```bash
curl -H "Authorization: Token token=<ZAMMAD_TOKEN>" \
  http://localhost:8000/api/v1/users?limit=1
# → 200 con JSON
```

> Sin rol **Agente** en el grupo del ticket, el `PUT` falla con 403/422 y el
> flujo lo registra en `Log Error`.

## 5.4 Variables de entorno (n8n)

En `envs/n8n.env` local (ignorado por git; plantilla en `envs/n8n.env.example`):

```bash
ZAMMAD_HOST=http://zammad-nginx:8080   # host INTERNO Docker, no localhost:8000
ZAMMAD_TOKEN=<token Agent de svc-n8n>
ZAMMAD_TOKEN_PROV=<token Admin de svc-zammad-prov>
```

Tras editarlas, **recrear n8n** (`env_file` solo se lee al crear el contenedor):

```bash
docker compose up -d --force-recreate n8n
```

## 5.5 Campos custom del ticket (una vez por instancia)

Opción recomendada — script idempotente (requiere `ZAMMAD_TOKEN_PROV`):

```bash
./scripts/zammad-ticket-objects.sh          # crea + migra
./scripts/zammad-ticket-objects.sh --check  # verifica presencia
docker compose restart zammad-railsserver zammad-scheduler zammad-websocket
```

Crea `snipe_asset_count` (integer), `snipe_asset_tags` y `snipe_asset_summary`
(textarea), visibles para el agente en vista/edición y ocultos en la creación.

Opción manual — Admin → Objetos → Ticket → 3 atributos con los mismos nombres
internos → *Update Database* → mismo reinicio.

## 5.6 Importar y activar el workflow en n8n

1. En cada n8n (casa/trabajo): Credentials → **Header Auth** nueva, nombre
   `Header Auth zammad` (o el que prefieras; la clave del mapa es
   `zammad_header`), Name `Authorization`, Value `Token token=<ZAMMAD_TOKEN>`
   escrito a mano (sin `\r`/espacios finales).
2. Anotar su ID en los mapas locales (ignorados por git):
   `envs/n8n-creds.{casa,trabajo}.json` → clave `zammad_header`.
   Igual con el workflow ya creado: `envs/n8n-workflows.{casa,trabajo}.json` →
   clave `zammad` (plantilla en los `.example.json`).
3. Remapear el snapshot (sabor casa, con sentinela
   `ZAMMAD_HEADER_PENDIENTE` hasta el paso 1):
   `./scripts/n8n-remap.sh --to trabajo "flows/zammad/Zammad enrich ticket assets.json"`
   e importar el resultado en la UI (o `push` cuando el vivo ya exista,
   verificado en trabajo: `push --to trabajo --restart`).
4. **Activar** el workflow en n8n (el snapshot viaja inactivo). Sin activar, el
   webhook responde 404 y Zammad agota sus 4 reintentos.
5. Copiar la **Production URL** del nodo `Zammad ticket created`
   (`http://<host>:5678/webhook/zammad-ticket-created`).

## 5.7 Webhook + Trigger en Zammad

**Webhook** (Admin → Gestionar → Webhooks → Nuevo):

| Campo | Valor |
|-------|-------|
| Nombre | `n8n enrich ticket` |
| Endpoint | `http://n8n:5678/webhook/zammad-ticket-created` (servicio Docker en red `net`) |
| Método | `POST` |
| Autenticación | ninguna (red interna; MVP sin HMAC) |
| Custom payload | activado: |

```json
{
  "ticket_id": "#{ticket.id}",
  "ticket_number": "#{ticket.number}",
  "customer_email": "#{ticket.customer.email}"
}
```

**Trigger** (Admin → Gestionar → Triggers → Nuevo):

| Campo | Valor |
|-------|-------|
| Nombre | `Enriquecer ticket con Snipe-IT` |
| Activated by | `Action` |
| Action execution | `Selective` |
| Condición | `Ticket → Action → is → created` |
| Acción | `Notification → Webhook → n8n enrich ticket` |

> Solo `created`: las actualizaciones del propio flujo (`PUT`) no re-disparan.

Alternativa por consola (mismo resultado, verificado 2026-09-10):

```bash
docker exec zammad-snipeit-zammad-railsserver-1 /opt/zammad/bin/rails runner \
  "Trigger.create!(name: 'Enriquecer ticket con Snipe-IT', \
  condition: {'ticket.action' => {'operator' => 'is', 'value' => 'create'}}, \
  perform: {'notification.webhook' => {'webhook_id' => '1'}}, \
  activator: 'action', execution_condition_mode: 'selective', \
  active: true, created_by_id: 1, updated_by_id: 1)"
```

> El `value` almacenado es `create` (la UI lo muestra como `created`) y el
> perform referencia `webhook_id` (ver `TriggerWebhookJob#webhook_id`).

## 5.8 Pruebas

1. Cliente con 2 activos asignados en Snipe-IT → crear ticket → customs con
   `2`/tags/resumen + nota interna visible para el agente.
2. Cambiar un activo en Snipe-IT → nuevo ticket → refleja el cambio.
3. Cliente inexistente en Snipe-IT → `0`/vacíos + nota explicativa.
4. Cliente sin activos → `0`/vacíos + nota.
5. Email con mayúsculas/espacios → match igual (normalización LOWER+trim).
6. Auditoría: `SELECT * FROM integration_sync_log WHERE entity='ticket' ORDER BY id DESC LIMIT 5;`
7. Confirmar que el `PUT` no genera una segunda ejecución del webhook.

> **Datos de prueba:** el caso positivo exige un email que exista en Zammad
> (customer del ticket) **y** en Snipe-IT (usuario con activos). En el lab no
> había solape: se creó el customer `adriana.leon@guayas.gob.ec` (1 activo,
> tag `1410107-000650`) y el ticket descartable id 3 / `72003`. Checklist
> interactivo: `docs/checklist-zammad-enrich-ticket-assets.html`.

## 5.9 Problemas frecuentes

| Síntoma | Causa probable |
|---------|----------------|
| Webhook 404 | Workflow inactivo en n8n, o path distinto a `zammad-ticket-created` |
| `Log Error` con 401 | `Header Auth zammad` con token viejo / usuario sin rol Agente en el grupo |
| `Log Error` con 422 | Falta un campo custom (§5.5) o el grupo no admite al usuario de integración |
| `ECONNREFUSED` a Zammad/Snipe | Host `localhost` en vez de `zammad-nginx:8080` / `snipe-it:80` |
| Campos vacíos en tickets viejos | Normal: los objetos nuevos no rellenan tickets existentes (solo los nuevos se enriquecen) |
| Sentinela sin remapear | Crear la credencial (§5.6.1), anotar IDs y re-ejecutar `n8n-remap.sh` (v1.3.0+) |
| 401 `Can't find User for Token` con token "correcto" | Si el `.env` tiene comentario inline (`TOKEN=abc # nota`), los lectores `cut -d= -f2-` lo pegan al valor. Los scripts ya recortan con `cut -d' ' -f1`; preferir comentarios en línea propia |
| `ok:false` con `ticket_id: 0` y `customer_email: ""` | `Extract Ticket` leyó fuera de `$json.body` (n8n envuelve el payload del webhook). > **Fix 2026-09-10:** leer `$json.body?.ticket_id` con fallback plano; verificado en exec 1833 (`integration_sync_log` ids 15-16). |
| `Log Error` con `{"code":"ERR_INVALID_HTTP_TOKEN"}` | Credencial Header Auth mal formada. Caso real 2026-09-10: el campo **Name** decía `Zammad ticket auth` (espacios = header name inválido → Node rechaza antes de enviar) y el **Value** era `=<token>` (sin prefijo `Token token=`). > **Fix 2026-09-10:** Name `Authorization`, Value `Token token=<token>` escrito a mano; no es 401/403. |
| `ok:true` pero el ticket no cambia (PUT 200, Rails muestra solo `{"id" => "3"}`) | Al nodo HTTP le falta `"sendBody": true`: n8n ignora `jsonBody` y envía cuerpo vacío. > **Fix 2026-09-10:** añadir `"sendBody": true` en `Update Zammad Ticket` + push; verificado por barrido de todos los POST/PUT/PATCH de `flows/*/*.json` (era el único sin la llave). |
| Token visible en `integration_sync_log` | `Log Error` serializaba `$json.error` crudo, que incluye `options.headers.Authorization`. > **Fix 2026-09-10:** `Log Error` solo guarda `{message, code, status}`; fila afectada redactada por SQL. Nunca guardar el error crudo de un HTTP con auth. |
| 422 `No lookup value found for 'customer'` al crear ticket por API | El customer debe existir; en el flujo real siempre existe (crea el ticket) |
