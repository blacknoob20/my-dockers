FROM alpine:latest as OCI_INSTANT_CLIENT

RUN mkdir -p /opt/oracle/client/11.2/network/admin

COPY ./oracle_client/* /opt/oracle/client/

ENV ORACLE_HOME=/opt/oracle/client/11.2

RUN \
 unzip /opt/oracle/client/instantclient-basic-linux.x64-11.2.0.4.0.zip -d /opt/oracle/client &&\
 mv /opt/oracle/client/instantclient_11_2/* $ORACLE_HOME/ &&\
 rm -R -f /opt/oracle/client/instantclient_11_2 &&\
 rm -f /opt/oracle/client/instantclient-basic-linux.x64-11.2.0.4.0.zip &&\
 unzip /opt/oracle/client/instantclient-sdk-linux.x64-11.2.0.4.0.zip -d /opt/oracle/client &&\
 mv /opt/oracle/client/instantclient_11_2/sdk/ $ORACLE_HOME/ &&\
 rm -R -f /opt/oracle/client/instantclient_11_2/ &&\
 rm -f /opt/oracle/client/instantclient-sdk-linux.x64-11.2.0.4.0.zip &&\
 ln -s $ORACLE_HOME/libclntsh.so.11.1 $ORACLE_HOME/libclntsh.so &&\
 ln -s $ORACLE_HOME/libocci.so.11.1 $ORACLE_HOME/libocci.so

FROM php:8.1-fpm-alpine

COPY --from=OCI_INSTANT_CLIENT /opt/oracle/client/ /opt/oracle/client/

ENV ORACLE_HOME=/opt/oracle/client/11.2
ENV LD_LIBRARY_PATH=$ORACLE_HOME
ENV PATH="$ORACLE_HOME:$PATH"

LABEL glibc="Instalación glibc libaio libnsl libzip-dev zip"

RUN apk update &&\
 apk add --no-cache\
 libaio\
 libnsl\
 libzip-dev\
 zip\
 libxml2-dev\
 libpng-dev\
 openldap-dev &&\
 ln -s /usr/lib/libnsl.so.3.0.0 $ORACLE_HOME/libnsl.so.1

LABEL oci8="Instalación PHP 8.1 ext OCI8"
RUN \
 docker-php-ext-configure oci8 --with-oci8=instantclient,$ORACLE_HOME &&\
 docker-php-ext-configure pdo_oci --with-pdo-oci=instantclient,$ORACLE_HOME &&\
 docker-php-ext-install -j$(nproc) oci8 zip soap calendar gd ldap pdo_oci &&\
 docker-php-ext-enable oci8 zip soap calendar gd ldap pdo_oci

COPY ./ini/* $PHP_INI_DIR/conf.d/
# Cambiar nombre php.ini-development a php.ini
RUN mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"