# Imagen php7.4-fpm-alpine-oci8

Imagen Docker optimizada para desarrollo y producción con PHP 7.4, Oracle Instant Client (OCI8), Xdebug, MySQL/MariaDB y otras extensiones útiles.

## Características principales

- **Base:** php:7.4-fpm-alpine (ligera y segura)
- **Oracle Instant Client 11.2:** Soporte para oci8 y pdo_oci
- **Xdebug 3.1.6:** Debugging remoto y profiling
- **MySQL/MariaDB:** Extensiones mysqli y pdo_mysql habilitadas
- **PostgreSQL:** Extensiones pdo_pgsql y pgsql
- **LDAP, GD, SOAP, ZIP, Calendar:** Listas para usar
- **Configuración de Xdebug lista para VSCode y debugging remoto**
- **Permisos y logs configurados para desarrollo**
- **Incluye php.ini personalizado y soporte para archivos .ini adicionales**

## Uso rápido

```bash
docker run -d --name php74-oci8 -p 9000:9000 php7.4-fpm-alpine-oci8
```

## Variables y configuración

- Puedes montar tu código en `/var/www/html`
- Personaliza la configuración PHP agregando archivos `.ini` en el build o montando un volumen
- Xdebug configurado para debugging remoto en el puerto 9003

## Ejemplo de extensiones habilitadas

- oci8, pdo_oci, mysqli, pdo_mysql, pdo_pgsql, ldap, gd, soap, zip, calendar, opcache, xdebug

## Uso típico

Ideal para proyectos que requieren conectividad con Oracle, MySQL/MariaDB y debugging avanzado en PHP 7.4.
