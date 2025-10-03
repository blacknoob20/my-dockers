
# Etapa builder para compilar pgvector
FROM postgres:15.6-alpine3.19 AS builder
RUN apk add --no-cache build-base postgresql-dev git make
WORKDIR /tmp
RUN git clone --branch v0.5.1 https://github.com/pgvector/pgvector.git
WORKDIR /tmp/pgvector
RUN make && make install

# Imagen final: solo Postgres y pgvector ya compilado
FROM postgres:15.6-alpine3.19


# Copiar los archivos de la extensión desde el builder (rutas estándar de instalación)
COPY --from=builder /usr/local/lib/postgresql/vector.so /usr/local/lib/postgresql/vector.so
COPY --from=builder /usr/local/share/postgresql/extension/vector.control /usr/local/share/postgresql/extension/vector.control
COPY --from=builder /usr/local/share/postgresql/extension/vector--*.sql /usr/local/share/postgresql/extension/

WORKDIR /