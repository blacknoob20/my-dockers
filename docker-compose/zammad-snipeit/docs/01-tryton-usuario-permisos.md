# 1. Configuración de Tryton — Usuario y Permisos para n8n

## Objetivo

Crear un usuario de servicio en Tryton con permisos de solo lectura para extraer datos de activos, empleados y terceros vía la API JSON-RPC.

---

## 1.1 Crear el grupo `integracion_n8n`

### Ruta
`Administración → Usuarios → Grupos`

### Pasos
1. Clic en **Nuevo**
2. Completar:
   - **Nombre**: `integracion_n8n`
   - **Descripción**: Grupo de solo lectura para integración vía API
3. **Guardar**

---

## 1.2 Asignar permisos al grupo

En la pestaña **Accesos** del grupo, agregar permisos **solo de lectura** para los siguientes modelos:

### Modelos de Activos

| Modelo Tryton | Descripción | R | W | C | D |
|---------------|-------------|---|---|---|---|
| `account.asset` | Activos (depreciación contable) | ✔ | ❌ | ❌ | ❌ |
| `asset.category` | Categorías de activos | ✔ | ❌ | ❌ | ❌ |
| `asset.depreciation.line` | Líneas de depreciación | ✔ | ❌ | ❌ | ❌ |

### Modelos de Empleados

| Modelo Tryton | Descripción | R | W | C | D |
|---------------|-------------|---|---|---|---|
| `company.employee` | Empleados | ✔ | ❌ | ❌ | ❌ |
| `company.department` | Departamentos | ✔ | ❌ | ❌ | ❌ |

### Modelos de Terceros (Parties)

| Modelo Tryton | Descripción | R | W | C | D |
|---------------|-------------|---|---|---|---|
| `party.party` | Personas / Empresas | ✔ | ❌ | ❌ | ❌ |
| `party.address` | Direcciones | ✔ | ❌ | ❌ | ❌ |
| `party.contact_mechanism` | Teléfonos, correos, etc. | ✔ | ❌ | ❌ | ❌ |

> **Nota**: Los permisos en Tryton se asignan **por grupo**. El usuario solo necesita pertenecer al grupo correcto.

---

## 1.3 Crear el usuario `svc_n8n`

### Ruta
`Administración → Usuarios → Usuarios`

### Pasos
1. Clic en **Nuevo**
2. Completar:
   - **Usuario**: `svc_n8n`
   - **Nombre completo**: `Integracion N8N`
   - **Correo electrónico**: (opcional)
3. En la pestaña **Grupos**, agregar el grupo `integracion_n8n`
4. En la pestaña **Preferencias**, definir la contraseña: `your_tryton_password_here` (ver `envs/n8n.env.example` `TRYTON_PASS`)
5. **Guardar**

---

## 1.4 Verificar acceso

### Prueba de login
```bash
curl -X POST "http://<tryton_host>:8000/<database>/" \
  -H "Content-Type: application/json" \
  -d '{
    "id": 0,
    "method": "common.db.login",
    "params": ["svc_n8n", {"password": "your_tryton_password_here", "device_cookie": null}, "es"]
  }'
```

### Respuesta esperada
```json
{
  "id": 0,
  "result": [2160, "<session_token>"]
}
```

### Prueba de lectura de activos
```bash
AUTH=$(echo -n "svc_n8n:<uid>:<session_token>" | base64 -w0)

curl -X POST "http://<tryton_host>:8000/<database>/" \
  -H "Content-Type: application/json" \
  -H "Authorization: Session $AUTH" \
  -d '{
    "id": 0,
    "method": "model.asset.search_read",
    "params": [[], 0, 3, null, ["id", "code", "name"], {}]
  }'
```

---

## 1.5 Resumen de credenciales

| Campo | Valor |
|-------|-------|
| URL Tryton | `http://192.168.56.102:8000` |
| Base de datos | `dbegoblocal` |
| Usuario | `svc_n8n` |
| Contraseña | `your_tryton_password_here` (ver `envs/n8n.env.example`) |
| Grupo | `integracion_n8n` |
| UID | `2160` |

---

## 1.6 Modelos disponibles en el servidor

### Modelo principal de activos
- **`asset`** — Modelo principal con ~19,339 registros
  - `code` — Código patrimonial (ej: `1410105-000001`)
  - `name` — Nombre/descripción
  - `asset_state` — Estado: `good`, `regular`, `bad`, `baja`, `repair`, `disuse`, `seized`
  - `actual_value` — Valor actual
  - `category.rec_name` — Categoría
  - `company.rec_name` — Institución
  - `current_owner.rec_name` — Titular actual

### Modelo de depreciación (alternativo)
- **`account.asset`** — Activos con información contable de depreciación
