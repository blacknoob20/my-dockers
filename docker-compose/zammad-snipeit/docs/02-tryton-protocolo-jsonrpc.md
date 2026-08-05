# 2. Protocolo JSON-RPC de Tryton

## Objetivo

Documentar el protocolo de comunicación con la API de Tryton para construir integraciones en n8n u otros sistemas.

---

## 2.1 Endpoint

```
POST http://<tryton_host>:8000/<database>/
```

| Header | Valor |
|--------|-------|
| `Content-Type` | `application/json` |

> **Importante**: Usar `application/json`, NO `application/json-rpc`.

---

## 2.2 Autenticación

### Paso 1: Login

```json
{
  "id": 0,
  "method": "common.db.login",
  "params": [
    "<user>",
    {"password": "<password>", "device_cookie": null},
    "es"
  ]
}
```

**Respuesta exitosa:**
```json
{
  "id": 0,
  "result": [<user_id>, "<session_token>"]
}
```

### Paso 2: Auth header para requests autenticados

```
Authorization: Session <base64(user:uid:session)>
```

**Ejemplo:**
```
user=svc_n8n, uid=2160, session=81fcb05e...
base64("svc_n8n:2160:81fcb05e...") → Authorization header
```

---

## 2.3 Métodos disponibles

### Lectura de datos (search_read)

```json
{
  "id": 0,
  "method": "model.<model_name>.search_read",
  "params": [
    [<domain>],
    <offset>,
    <limit>,
    <order>,
    [<fields>],
    <context>
  ]
}
```

**Parámetros:**

| Índice | Tipo | Descripción |
|--------|------|-------------|
| 0 | Array | Dominio de búsqueda (array vacío = todos) |
| 1 | Integer | Offset (desde qué registro) |
| 2 | Integer/null | Limit (null = sin límite) |
| 3 | Array/null | Order (null = orden por defecto) |
| 4 | Array | Campos a retornar |
| 5 | Object | Contexto (idioma, moneda, etc.) |

**Ejemplo — Obtener 5 activos:**
```json
{
  "id": 0,
  "method": "model.asset.search_read",
  "params": [
    [],
    0, 5, null,
    ["id", "code", "name", "asset_state", "actual_value"],
    {}
  ]
}
```

### Lectura de registro único (read)

```json
{
  "id": 0,
  "method": "model.<model_name>.read",
  "params": [[<id>], [<fields>], {}]
}
```

### Contar registros (search + count)

```json
{
  "id": 0,
  "method": "model.<model_name>.search",
  "params": [[], 0, null, null, <count>]
}
```

---

## 2.4 Formato de respuesta

### Éxito
```json
{
  "id": 0,
  "result": [<datos>]
}
```

### Error
```json
{
  "id": 0,
  "error": ["<tipo_error>", "<mensaje>", <traceback>]
}
```

---

## 2.5 Campos especiales

### Relaciones (Many2One)
Para obtener el nombre de una relación, usar `<campo>.rec_name`:

```json
["category", "category.rec_name", "company", "company.rec_name"]
```

**Respuesta:**
```json
{
  "category": 195,
  "category.": {"id": 195, "rec_name": "1410105-VEHICULO"},
  "company": 1,
  "company.": {"id": 1, "rec_name": "GOBIERNO PROVINCIAL DEL GUAYAS"}
}
```

### Fechas
```json
{
  "__class__": "datetime",
  "year": 2025,
  "month": 1,
  "day": 5,
  "hour": 21,
  "minute": 28,
  "second": 23
}
```

### Decimales
```json
{
  "__class__": "Decimal",
  "decimal": "14783.8"
}
```

---

## 2.6 Rate limit

El servidor de producción (`financieroprueba.guayas.gob.ec`) tiene un rate limit agresivo:
- No hay headers `Retry-After` o `X-RateLimit-Reset`
- El bloqueo dura largo tiempo (>15 min)
- Cada request fallido resetea el contador

**Recomendación**: Máximo 1 request cada 3 segundos.

---

## 2.7 User Applications (API Keys)

Tryton soporta User Application keys, pero solo funcionan con rutas custom decoradas con `@user_application('app_name')`. El endpoint JSON-RPC estándar NO acepta bearer tokens.

Para integraciones vía JSON-RPC, usar siempre session-based auth.

---

## 2.8 Session validation

Las sesiones en Tryton no tienen un TTL definido, pero expiran por inactividad. Para validar si una sesión cacheada sigue vigente sin hacer una request pesada:

### Request
```json
{
  "id": 0,
  "method": "model.res.user.get_preferences",
  "params": [false, {}]
}
```

Headers must include `Authorization: Session <base64(user:uid:session)>`.

### Respuesta — sesión vigente
```json
{
  "id": 0,
  "result": {
    "id": 2160,
    "name": "svc_n8n",
    ...
  }
}
```

### Respuesta — sesión expirada
```json
{
  "id": 0,
  "error": ["TrytonError", "Session expired", ...]
}
```

### Patrón recomendado
1. Cachear la sesión en memoria estática
2. Al empezar, validar con `get_preferences`
3. Si expiró → hacer `common.db.login` de nuevo
4. Reintentar máximo 3 veces antes de alertar
