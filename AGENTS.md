# Reglas del repo

## Sincronizar specs y docs (obligatorio, no preguntar)

Cuando un cambio modifique comportamiento descrito en specs o docs,
actualizarlos **en el mismo changeset**, sin esperar a que el usuario
lo pida. La tarea no está completa hasta que specs/docs reflejen el código.

Correspondencia (stack `docker-compose/zammad-snipeit/`):

| Cambio | Actualizar |
|--------|------------|
| `flows/**/*.json` (nodos, expresiones, conexiones) | `.ai/specs/tryton-activos.md` (sección del workflow) y espejo en `docs/04-workflows-sincronizacion.md` |
| `docker-compose.yml` / `envs/*.env` | Tablas de volúmenes/arquitectura/credenciales de `AGENTS.md` del stack; si hay token/secret nuevo, `docs/manual-implementacion.md` |
| Estructura de tablas (`sql/init-sync-tables.sql`) | Sección "Tablas de mapeo" del spec + comportamiento de `scripts/reset-sync.sh` |
| Fix de bug o gotcha | Fila en "Errores conocidos" (spec y docs/04) con nota fechada `> **Fix YYYY-MM-DD:** ...` |

Convenciones:
- Las notas de fix llevan fecha y explican causa raíz + corrección (estilo existente).
- `flows/*.json` son snapshots: si se cambia en la UI de n8n, re-exportar el archivo.
- Nunca documentar secretos literales nuevos en docs públicos del repo.
