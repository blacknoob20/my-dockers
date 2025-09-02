FROM php:7.4-fpm-alpine AS oci_instant_client

RUN mkdir -p /opt/oracle/client/minify
RUN mkdir -p /opt/oracle/client/11.2/network/admin
RUN apk update && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
  autoconf \
  automake \
  gcc \
  g++ \
  make \
  linux-headers \
  libaio \
  libnsl \
  libzip-dev \
  libxml2-dev \
  libpng-dev \
  postgresql-dev \
  openldap-dev \
  zip \
  curl \
  bash

COPY ./oracle_client/* /opt/oracle/client/

ENV ORACLE_HOME=/opt/oracle/client/11.2
ENV LD_LIBRARY_PATH=$ORACLE_HOME
ENV PATH="$ORACLE_HOME:$PATH"

RUN \
  unzip /opt/oracle/client/instantclient-basic-linux.x64-11.2.0.4.0.zip -d /opt/oracle/client &&\
  cp /opt/oracle/client/instantclient_11_2/* /opt/oracle/client/minify &&\
  rm -f\
  /opt/oracle/client/minify/BASIC_README\
  /opt/oracle/client/minify/*.jar &&\
  mv /opt/oracle/client/instantclient_11_2/* $ORACLE_HOME/ &&\
  rm -R -f /opt/oracle/client/instantclient_11_2 &&\
  rm -f /opt/oracle/client/instantclient-basic-linux.x64-11.2.0.4.0.zip &&\
  unzip /opt/oracle/client/instantclient-sdk-linux.x64-11.2.0.4.0.zip -d /opt/oracle/client &&\
  mv /opt/oracle/client/instantclient_11_2/sdk/ $ORACLE_HOME/ &&\
  rm -R -f /opt/oracle/client/instantclient_11_2/ &&\
  rm -f /opt/oracle/client/instantclient-sdk-linux.x64-11.2.0.4.0.zip &&\
  ln -s $ORACLE_HOME/libclntsh.so.11.1 /opt/oracle/client/minify/libclntsh.so &&\
  ln -s $ORACLE_HOME/libocci.so.11.1 /opt/oracle/client/minify/libocci.so &&\
  ln -s $ORACLE_HOME/libclntsh.so.11.1 $ORACLE_HOME/libclntsh.so &&\
  ln -s $ORACLE_HOME/libocci.so.11.1 $ORACLE_HOME/libocci.so

LABEL glibc="Instalación glibc libaio libnsl libzip-dev zip"

RUN apk update &&\
  apk add --no-cache\
  libpq\
  libaio\
  libnsl\
  libzip-dev\
  zip\
  libxml2-dev\
  libpng-dev\
  postgresql-dev\
  openldap-dev &&\
  ln -s /usr/lib/libnsl.so.3.0.0 $ORACLE_HOME/libnsl.so.1

LABEL oci8="Instalación PHP 8.1 ext OCI8"

RUN \
  docker-php-ext-configure pdo_pgsql &&\
  docker-php-ext-configure oci8 --with-oci8=instantclient,$ORACLE_HOME &&\
  docker-php-ext-configure pdo_oci --with-pdo-oci=instantclient,$ORACLE_HOME &&\
  docker-php-ext-install -j$(nproc) oci8 zip soap calendar gd ldap pdo_oci pdo_mysql pdo_pgsql mysqli
RUN pecl install xdebug-3.1.6 && docker-php-ext-enable xdebug
RUN apk del .build-deps

FROM php:7.4-fpm-alpine

COPY --from=oci_instant_client /opt/oracle/client/minify/ /opt/oracle/client/11.2/
COPY --from=oci_instant_client /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=oci_instant_client /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini /usr/local/etc/php/conf.d/

ENV ORACLE_HOME=/opt/oracle/client/11.2
ENV LD_LIBRARY_PATH=$ORACLE_HOME
ENV PATH="$ORACLE_HOME:$PATH"

RUN apk update &&\
  apk add --no-cache\
  libzip-dev\
  libpng-dev\
  openldap-dev\
  libnsl\
  libaio\
  libpq &&\
  ln -s /usr/lib/libnsl.so.3.0.0 $ORACLE_HOME/libnsl.so.1

RUN docker-php-ext-enable zip soap calendar gd ldap oci8 pdo_oci pdo_mysql mysqli pdo_pgsql opcache xdebug

# Configurar Xdebug con valores fijos para evitar problemas con variables de entorno
RUN echo "xdebug.mode=debug" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini && \
  echo "xdebug.client_host=host.docker.internal" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini && \
  echo "xdebug.client_port=9003" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini && \
  echo "xdebug.start_with_request=yes" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini && \
  echo "xdebug.discover_client_host=0" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini && \
  echo "xdebug.log=/tmp/xdebug/xdebug.log" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini && \
  echo "xdebug.log_level=7" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini

# Crear directorio y archivo de log para Xdebug con permisos adecuados
RUN mkdir -p /tmp/xdebug && touch /tmp/xdebug/xdebug.log && chmod 777 /tmp/xdebug /tmp/xdebug/xdebug.log

# Copiar archivos ini personalizados si los tienes
COPY ./ini/* $PHP_INI_DIR/conf.d/

# Cambiar php.ini-development a php.ini para usar configuración base
RUN mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"
