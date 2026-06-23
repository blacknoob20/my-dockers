# 3. Integración Tryton → n8n

## Objetivo

Construir un workflow en n8n que extrae activos de Tryton via JSON-RPC y los retorna como JSON.

---

## 3.1 Flujo del workflow

```
Webhook (GET /tryton-activos)
    ↓
HTTP Request (Login → common.db.login)
    ↓
Set (Construir Auth header)
    ↓
HTTP Request (Buscar activos → model.asset.search_read)
    ↓
Respond to Webhook (JSON)
```

---

## 3.2 Nodo 1: Webhook

| Campo | Valor |
|-------|-------|
| Method | GET |
| Path | `tryton-activos` |
| Response | Last Node |

---

## 3.3 Nodo 2: HTTP Request (Login)

| Campo | Valor |
|-------|-------|
| Method | POST |
| URL | `http://192.168.56.102:8000/dbegoblocal/` |
| Content Type | JSON |

**Body:**
```json
{
  "id": 0,
  "method": "common.db.login",
  "params": [
    "svc_n8n",
    {"password": "12345678", "device_cookie": null},
    "es"
  ]
}
```

---

## 3.4 Nodo 3: Set (Auth Header)

**Expression:**
```javascript
{
  "auth": "Session {{ $base64Encode('svc_n8n:' + $json.result[0] + ':' + $json.result[1]) }}",
  "user_id": {{ $json.result[0] }}
}
```

---

## 3.5 Nodo 4: HTTP Request (Buscar Activos)

| Campo | Valor |
|-------|-------|
| Method | POST |
| URL | `http://192.168.56.102:8000/dbegoblocal/` |
| Content Type | JSON |

**Headers:**
```
Authorization: {{ $json.auth }}
```

**Body:**
```json
{
  "id": 0,
  "method": "model.asset.search_read",
  "params": [
    [],
    0, 100, null,
    [
      "id", "code", "name", "asset_state", "asset_type_new",
      "actual_value", "category.rec_name", "company.rec_name",
      "current_owner.rec_name"
    ],
    {}
  ]
}
```

---

## 3.6 Nodo 5: Respond to Webhook

| Campo | Valor |
|-------|-------|
| Response Code | 200 |
| Content Type | JSON |

**Body:**
```json
{
  "success": true,
  "total": {{ $json.result.length }},
  "activos": {{ JSON.stringify($json.result) }}
}
```

---

## 3.7 Prueba del workflow

### URL del webhook
```
http://localhost:5678/webhook/tryton-activos
```

### Prueba con curl
```bash
curl "http://localhost:5678/webhook/tryton-activos"
```

### Respuesta esperada
```json
{
  "success": true,
  "total": 100,
  "activos": [
    {
      "id": 134240,
      "code": "1410105-000001",
      "name": "EQUIPO PESADO Y EXTRAPESADO : VOLQUETA DE 12 M3",
      "asset_state": "baja",
      "actual_value": {"__class__": "Decimal", "decimal": "14783.8"},
      "category.rec_name": "1410105-VEHICULO",
      "company.rec_name": "GOBIERNO PROVINCIAL DEL GUAYAS",
      "current_owner.rec_name": "ROMERO BALBERA RAFAEL STEVEN"
    }
  ]
}
```

---

## 3.8 Variables de entorno (producción)

| Variable | Valor |
|----------|-------|
| `TRYTON_URL` | `https://financieroprueba.guayas.gob.ec` |
| `TRYTON_DB` | `dbegob2bak` |
| `TRYTON_USER` | `svc_n8n` |
| `TRYTON_PASS` | `***` |

> **Nota**: En producción, el rate limit de HAProxy puede bloquear requests frecuentes.
