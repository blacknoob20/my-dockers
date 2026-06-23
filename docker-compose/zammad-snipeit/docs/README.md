# Documentación — Integración Tryton con n8n

## Estructura

| Archivo | Contenido |
|---------|-----------|
| `01-tryton-usuario-permisos.md` | Creación de usuario y grupo en Tryton |
| `02-tryton-protocolo-jsonrpc.md` | Protocolo JSON-RPC de Tryton |
| `03-integracion-n8n-tryton.md` | Workflow en n8n para extraer activos |

## Orden de lectura

1. **01** — Configurar usuario y permisos en Tryton
2. **02** — Entender el protocolo de comunicación
3. **03** — Implementar el workflow en n8n

## Requisitos

- Tryton 6.x o superior
- n8n instalado (Docker o standalone)
- Usuario `svc_n8n` con permisos de solo lectura
- Acceso a la API JSON-RPC de Tryton
