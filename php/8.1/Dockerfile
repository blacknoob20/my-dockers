FROM php:8.1-fpm-alpine as oci_instant_client

RUN mkdir -p /opt/oracle/client/minify &&\
  mkdir -p /opt/oracle/client/11.2/network/admin

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
  apk add --no-cache --update linux-headers\
  autoconf\
  automake\
  gcc\
  g++\
  make\
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
RUN pecl install -f xdebug

LABEL oci8="Instalación PHP 8.1 ext OCI8"

RUN \
  docker-php-ext-configure pdo_pgsql &&\
  docker-php-ext-configure oci8 --with-oci8=instantclient,$ORACLE_HOME &&\
  docker-php-ext-configure pdo_oci --with-pdo-oci=instantclient,$ORACLE_HOME &&\
  docker-php-ext-install -j$(nproc) oci8 zip soap calendar gd ldap pdo_oci pdo_mysql pdo_pgsql opcache

FROM php:8.1-fpm-alpine

COPY --from=oci_instant_client /opt/oracle/client/minify/ /opt/oracle/client/11.2/
COPY --from=oci_instant_client /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/

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

RUN docker-php-ext-enable zip soap calendar gd ldap oci8 pdo_oci pdo_mysql pdo_pgsql opcache xdebug &&\
  echo "opcache.enable=1" >> "$PHP_INI_DIR/conf.d/docker-php-ext-opcache.ini" &&\
  echo "opcache.enable_cli=1" >> "$PHP_INI_DIR/conf.d/docker-php-ext-opcache.ini" &&\
  echo "xdebug.idekey=VSCODE" >> "$PHP_INI_DIR/conf.d/docker-php-ext-xdebug.ini" &&\
  echo "xdebug.mode=develop,debug" >> "$PHP_INI_DIR/conf.d/docker-php-ext-xdebug.ini" &&\
  echo "xdebug.client_host=host.docker.internal" >> "$PHP_INI_DIR/conf.d/docker-php-ext-xdebug.ini" &&\
  echo "xdebug.client_port=9003" >> "$PHP_INI_DIR/conf.d/docker-php-ext-xdebug.ini" &&\
  echo "xdebug.log=/tmp/xdebug/xdebug.log" >> "$PHP_INI_DIR/conf.d/docker-php-ext-xdebug.ini" &&\
  echo "xdebug.log_level=7" >> "$PHP_INI_DIR/conf.d/docker-php-ext-xdebug.ini" &&\
  echo "xdebug.start_with_request=yes" >> "$PHP_INI_DIR/conf.d/docker-php-ext-xdebug.ini"

COPY ./ini/* $PHP_INI_DIR/conf.d/
# Cambiar nombre php.ini-development a php.ini
RUN mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"