# Documentación — Integración Tryton con n8n

## Estructura

| Archivo | Contenido |
|---------|-----------|
| `01-tryton-usuario-permisos.md` | Creación de usuario y grupo en Tryton |
| `02-tryton-protocolo-jsonrpc.md` | Protocolo JSON-RPC de Tryton |
| `03-integracion-n8n-tryton.md` | Sub-workflow de autenticación y consumo del login |
| `04-workflows-sincronizacion.md` | Workflows de sincronización Tryton → Snipe-IT (categorías, modelos, estados, activos) |

## Specs

| Archivo | Contenido |
|---------|-----------|
| `.ai/specs/tryton-activos.md` | Spec canónico: arquitectura, contratos de entrada/salida, tablas de mapeo, errores conocidos |

Los exports de los workflows (snapshots de n8n) viven en `flows/`:

| Archivo | Workflow |
|---------|----------|
| `flows/Tryton login.json` | Autenticación |
| `flows/Tryton sync categories.json` | Categorías |
| `flows/Tryton sync models.json` | Modelos |
| `flows/Tryton sync statuses.json` | Status labels |
| `flows/Tryton sync assets.json` | Workflow principal |

## Orden de lectura

1. **01** — Configurar usuario y permisos en Tryton
2. **02** — Entender el protocolo de comunicación
3. **03** — Implementar el sub-workflow de autenticación
4. **04** — Implementar los workflows de sincronización
5. **Spec** — Referencia canónica de contratos y casos límite

## Requisitos

- Tryton 6.x o superior
- n8n instalado (Docker o standalone)
- Usuario `svc_n8n` con permisos de solo lectura
- Acceso a la API JSON-RPC de Tryton
- Variables de entorno `TRYTON_HOST`, `TRYTON_LOGIN_USER`, `TRYTON_LOGIN_PASS`, `SNIPE_HOST`

## Mantenimiento de los exports

Al modificar un workflow en la UI de n8n, re-exportarlo:

```bash
docker compose exec n8n n8n export:workflow --id=<WORKFLOW_ID> --pretty --output=/tmp/<nombre>.json
docker compose cp n8n:/tmp/<nombre>.json flows/<Nombre workflow>.json
```

IDs de referencia:

| Workflow | ID |
|----------|----|
| Tryton login | `lwtmczcb4xwWrwvN` |
| Tryton sync categories | `6K1Olue3CsIyALJB` |
| Tryton sync models | `Q5X3iqntFS1etrPW` |
| Tryton sync statuses | `CisxFC1TxerOtZkG` |
| Tryton sync assets | `1k6JvwtUeXcHnAKe` |
