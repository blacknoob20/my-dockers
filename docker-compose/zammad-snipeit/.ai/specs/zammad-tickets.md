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

### Nodos Code — manual de mantenimiento (clean code)

Los 3 nodos `Code` son el manual del flujo; cada uno lleva encabezado con
propósito, entradas, salida y reglas de negocio, constantes con mensajes
literales y helpers puros. No hay cambio de comportamiento (solo legibilidad):

- **Match Snipe User** (`flows/zammad/Zammad enrich ticket assets.json:134`):
  helpers `normalizeEmail` / `isSnipeFetchError` / `findExactEmailMatches` /
  `sortByIdAsc`; constante `FALLBACK_MAX_ID = 9e15`. Lêe
  `$('Extract Ticket')` + `$input.body.rows` de `Find Snipe User`, compara
  exacta `LOWER` y ante duplicados elige `id` menor.
- **Build Enrichment** (`…:224`): helpers arrow `isFetchError` / `sortByAssetTag` /
  `formatAssetBlock` / `buildAsciiTable` / `buildSummaryBlock`; constantes `MSG_FETCH_ERROR`,
  `MSG_NO_ASSETS`, `FALLBACK_MODEL/CATEGORY/STATUS/TAG/SERIAL` (`FALLBACK_CATEGORY='Categoría?'`),
  `TABLE_HEADERS=['#','MODELO','CATEGORIA','TAG','ESTADO','S/N']` y helpers `sanitizeCell`/`padCell`.
  Ordena por `asset_tag`, arma el bloque UX 5 líneas para `summary` (`ACTIVOS SNIPE-IT (N)` + `----` +
  `NN modelo` / `   categoría` / `   tag` / `   estado` / `   S/N serial`, blank line) con
  `r.category.name` (identifica mouse/monitor/teclado/licencia/etc) y
  `note_body` como tabla ASCII con anchos `max(header, celdas)` +2, `border` `+---+`, header `| # | MODELO |…|` y filas `| 01 | … |` (celdas sanitizadas `\r/\n/\t/|→/`, `padEnd`, monospace `text/plain`, alineación perfecta); si `!body` o `0` usa las notas del §Casos.
- **Build Empty (no user)** (`…:278`): constante `MSG_SNIPE_FETCH_ERROR` y
  helper `buildMissingUserNote(email)`. Lee solo `Match Snipe User`
  (siempre ejecutado en su rama); si `snipe_error` nota de reintento, si no
  `Snipe-IT no tiene usuario con email …`; siempre `count 0 / vacíos`.

> **Refactor 2026-09-14 (clean code):** reescritura solo legibilidad, verificado
> con harness: duplicados id menor, sin match, error red/API, body sin rows,
> tags desordenados, 4 activos reales, fallbacks `Modelo?/Categoría?/Estado?/s/n` y 0
> activos. Comportamiento y literales idénticos; no requiere push funcional
> (mismo `versionId` salvo que se re-exporte).

> **Fix 2026-09-14 (categoría):** `Build Enrichment` añade 2ª línea `r.category.name` por activo
> (5 líneas/bloque) para identificar tipo real (mouse/monitor/teclado/licencia/etc).
> Antes solo mostraba modelo/tag/estado/serial y no se distinguía qué era el activo.
> Verificado con `/api/v1/hardware` live: `category.name` (ej. `EQUIPO DE PROYECCION`, `CPU`, `MOUSE`);
> fallback `Categoría?` si ausente. Ejemplo actualizado abajo.

### Contrato de enriquecimiento

| Campo Zammad         | Tipo     | Origen |
|----------------------|----------|--------|
| `snipe_asset_count`  | integer  | `rows.length` de `/hardware` |
| `snipe_asset_tags`   | textarea | `asset_tag` unidos por `, ` |
| `snipe_asset_summary`| textarea | Bloque UX `ACTIVOS SNIPE-IT (N)` + `--------------------` + N bloques `NN modelo` / `   categoría` / `   tag` / `   estado` / `   S/N serial` (orden por `asset_tag`, `NN` 01.., categoría=`r.category.name`, estado=`status_label.name` original, serial=`r.serial\|\|s/n`); vacío si `N=0` |
| artículo             | note     | `type: note`, `internal: true`, `sender: Agent`, `content_type: text/plain` — body = tabla ASCII `ACTIVOS SNIPE-IT (N)` + `+---+`/`| # | MODELO | CATEGORIA | TAG | ESTADO | S/N |`/`+---+` + N filas `| 01 | modelo | categoría | tag | estado | serial |` (orden por `asset_tag`, anchos `max(header, celdas)` +2, celdas sanitizadas sin `\r/\n/\t/|`, `padEnd`, monospace, alineación perfecta) o nota explicativa si `N=0`/`error` |

Provisionados una sola vez por instancia con
`scripts/zammad-ticket-objects.sh` (API Object Manager + migraciones +
reinicio obligatorio de workers). Ver `docs/05-integracion-zammad-snipeit.md`.

### Casos

| Caso | Comportamiento |
|------|----------------|
| Usuario con N activos | `snipe_asset_count=N`, `tags` con N, `summary`=bloque `ACTIVOS SNIPE-IT (N)` + `--------------------` + `NN modelo`/`   categoría`/`   tag`/`   estado`/`   S/N serial` (01.., orden `asset_tag`, 5 líneas por activo, blank line entre bloques, categoría=`r.category.name` identifica mouse/monitor/etc, datos reales Snipe-IT sin conversión) + nota interna tabla ASCII `ACTIVOS SNIPE-IT (N)` + `+---+`/`| # | MODELO | CATEGORIA | TAG | ESTADO | S/N |`/`+---+`/`| 01 | modelo | categoría | tag | estado | serial |` (anchos dinámicos `max(header, celdas)` +2, `padEnd`, sanitizada, alineación perfecta) |
| Usuario sin activos | `0` / vacíos + nota "Snipe-IT no reporta activos asignados…" |
| Email sin match en Snipe-IT | `0` / vacíos + nota "Snipe-IT no tiene usuario con email …" |
| Webhook sin email | `0` / vacíos + nota "Webhook sin email de cliente…" |
| Fallo red/API Snipe-IT | Degrada a nota de error (no tumba la ejecución); si el `PUT` falla, `Log Error` + `ok: false` al webhook (Zammad reintenta hasta 4 veces) |
| Email duplicado en Snipe-IT | Gana el id menor (mismo criterio que `Bulk Save Users`, fix 2026-09-03) |
| >100 activos por usuario | Truncado a 100 (`limit=100`); documentar si aparece el caso |

> **Formato 2026-09-14 (UX 5 líneas, datos reales) — `snipe_asset_summary`:** una línea por dato, sin etiquetas largas, valores originales Snipe-IT. Ejemplo con 2 activos reales (`r.model.name`, `r.category.name`, `r.asset_tag`, `r.status_label.name`, `r.serial`):
> ```
> ACTIVOS SNIPE-IT (4)
> --------------------
> 01 POWERLITE118
>    EQUIPO DE PROYECCION
>    1410107-000650
>    good: Bueno
>    S/N s/n
>
> 02 DELL-OPTIPLEX
>    CPU
>    1410107-000651
>    good: Bueno
>    S/N 12345
> ```
> Categoría = `r.category.name` (ej. `MOUSE`, `MONITOR`, `TECLADO`, `SOFTWARE`, `CPU`, `EQUIPO DE PROYECCION`); identifica qué es el activo.
> Estado y S/N son los registrados en Snipe-IT (no convertidos a `OK`/`MAL`); `s/n` si `serial` vacío. Ver `Build Enrichment` en snapshot. Fixture anterior `72006` con `OK`/`MAL` ficticio queda como histórica.

> **Formato 2026-09-15 (tabla ASCII, `note_body`):** solo la nota interna usa tabla ASCII con alineación perfecta (`text/plain` monospace). Anchos = `max(header, celdas)` +2, bordes `+---+`, celdas sanitizadas sin `\r/\n/\t/|→/` y `padEnd`. `snipe_asset_summary` conserva el bloque 5 líneas anterior. Ejemplo 2 activos:
> ```
> ACTIVOS SNIPE-IT (2)
> +----+---------------+----------------------+---------------+-------------+--------+
> | #  | MODELO        | CATEGORIA            | TAG           | ESTADO      | S/N    |
> +----+---------------+----------------------+---------------+-------------+--------+
> | 01 | POWERLITE118  | EQUIPO DE PROYECCION | 1410107-000650| good: Bueno | s/n    |
> | 02 | DELL-OPTIPLEX | CPU                  | 1410107-000651| good: Bueno | 12345  |
> +----+---------------+----------------------+---------------+-------------+--------+
> ```
> Alineación garantizada en texto generado; el wrap visual de Zammad no rompe columnas si el panel es estrecho (monospace). Ver `buildAsciiTable` en snapshot.

> **Fix 2026-09-15 (tabla ASCII nota):** `Build Enrichment` separa `summary` (bloque 5 líneas) de `note` (tabla ASCII); añadidos `TABLE_HEADERS`, `sanitizeCell`/`padCell`/`buildAsciiTable`; fallbacks y orden `asset_tag` intactos. Perfecta alineación por cálculo dinámico de anchos; sin columnas torcidas con textos largos/acentos/pipes/saltos.

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
| Push del flujo a casa falla (`no hay acceso a docker-postgres-1`) | `n8n-remap.sh` < v1.3.1 fijaba el contenedor del compose Linux; en Mac lab el postgres de n8n es `dbs-postgres`. > **Fix 2026-09-15 (v1.3.1):** auto-detección (`--db-cont` > `N8N_DB_CONT` > auto) + aviso si el mapa destino no define `zammad_header`; requiere claves `zammad`/`zammad_header` en los mapas locales (paso 2 de `docs/05` §5.6). |
