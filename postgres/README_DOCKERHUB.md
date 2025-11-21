# PostgreSQL 15.6 + pgvector (Alpine)

Imagen Docker personalizada basada en `postgres:15.6-alpine3.19` que incluye la extensión `pgvector` compilada (pgvector v0.5.1).

Esta imagen facilita ejecutar PostgreSQL con soporte para vectores (embeddings) mediante la extensión `pgvector`, ideal para búsquedas semánticas y sistemas RAG.

## Características

- **Base**: `postgres:15.6-alpine3.19`.
- **Extensión**: `pgvector` compilada desde fuente (v0.5.1).
- **Multi-stage build**: la compilación de `pgvector` se realiza en una etapa `builder` y solo se copian los artefactos necesarios a la imagen final.

## Etiquetas y compatibilidad

- PostgreSQL: 15.6
- pgvector: v0.5.1
- Base: Alpine 3.19

(Ajusta la etiqueta que publiques en Docker Hub según la convención que uses, por ejemplo `usuario/pg15-vector:15.6-alpine`.)

## Cómo construir localmente

Desde el directorio donde está el `Dockerfile`:

```bash
docker build -t pg15vector-alpine .
```

## Ejecutar la imagen (ejemplo rápido)

Ejecutar con variables de entorno estándar de Postgres y un volumen para persistencia:

```bash
docker run -d \
  --name pg15-vector \
  -e POSTGRES_PASSWORD=mi_contraseña \
  -e POSTGRES_USER=mi_usuario \
  -e POSTGRES_DB=mi_bd \
  -v pgdata:/var/lib/postgresql/data \
  -p 5432:5432 \
  pg15vector-alpine
```

## Docker Compose (fragmento)

```yaml
version: '3.8'
services:
  db:
    image: pg15vector-alpine
    environment:
      POSTGRES_USER: mi_usuario
      POSTGRES_PASSWORD: mi_contraseña
      POSTGRES_DB: mi_bd
    volumes:
      - pgdata:/var/lib/postgresql/data
    ports:
      - "5432:5432"

volumes:
  pgdata:
```

## Habilitar y usar `pgvector`

Conéctate a la base de datos (psql, pgAdmin, DBeaver, etc.) y ejecuta:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

Ejemplo básico de uso — crea una tabla con un campo vectorial (aquí usamos dimensión 1536 como ejemplo):

```sql
CREATE TABLE items (
  id SERIAL PRIMARY KEY,
  embedding VECTOR(1536),
  metadata JSONB
);

INSERT INTO items (embedding, metadata) VALUES
('[0.01, 0.02, 0.03, ...]'::vector, '{"name": "ejemplo"}');
```

Búsqueda por similitud (distancia L2 o coseno según la configuración):

```sql
SELECT id, metadata, embedding <-> '[0.01, 0.02, ...]'::vector AS distance
FROM items
ORDER BY distance
LIMIT 5;
```

Crear índice (ejemplo con `ivfflat`):

```sql
CREATE INDEX ON items USING ivfflat (embedding vector_l2_ops) WITH (lists = 100);
-- Después de crear el índice, ejecutar ANALYZE para que planners use el índice correctamente
ANALYZE items;
```

Ajusta la dimensión del vector a la que produce tu modelo de embeddings (por ejemplo 1536 para OpenAI ada/embeddings, o 768/1024 según el modelo).

## Cómo publicar en Docker Hub

1. Inicia sesión en Docker Hub:

```bash
docker login
```

2. Etiqueta la imagen con tu repositorio de Docker Hub:

```bash
docker tag pg15vector-alpine tuusuario/pg15vector:15.6-alpine
```

3. Empuja la imagen:

```bash
docker push tuusuario/pg15vector:15.6-alpine
```

## Notas y recomendaciones

- La imagen compila `pgvector` en una etapa `builder` para mantener la imagen final ligera.
- Si vas a usar cargas de trabajo intensivas, considera cambiar a una imagen de Postgres no-Alpine basada en Debian/Ubuntu para compatibilidad y rendimiento de paquetes nativos.
- Verifica la versión de `pgvector` y actualiza la rama/tag si necesitas funciones nuevas.

## Licencia

La imagen incluye PostgreSQL y la extensión `pgvector`. Revisa las licencias upstream de cada proyecto si lo vas a redistribuir con propósitos comerciales.

---

Si quieres, puedo:

- Generar el `README.md` directamente en el directorio del Dockerfile (sobrescribir o añadir).
- Añadir ejemplos adaptados a la dimensión de embeddings que uses.
- Añadir etiquetas y CI/CD para construir y publicar automáticamente en Docker Hub.
