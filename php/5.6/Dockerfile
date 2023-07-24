FROM alpine:latest as OCI_INSTANT_CLIENT

RUN mkdir -p /opt/oracle/client/11.2/network/admin

COPY ./oracle_client/* /opt/oracle/client/

ENV ORACLE_HOME=/opt/oracle/client/11.2
ENV LD_LIBRARY_PATH="$ORACLE_HOME:$LD_LIBRARY_PATH"
ENV PATH="$ORACLE_HOME:$PATH"

RUN \
 unzip /opt/oracle/client/instantclient-basic-linux.x64-11.2.0.4.0.zip -d /opt/oracle/client &&\
 mv /opt/oracle/client/instantclient_11_2/* $ORACLE_HOME/ &&\
 rm -R -f /opt/oracle/client/instantclient_11_2 &&\
 rm -f /opt/oracle/client/instantclient-basic-linux.x64-11.2.0.4.0.zip &&\
 unzip /opt/oracle/client/instantclient-sdk-linux.x64-11.2.0.4.0.zip -d /opt/oracle/client &&\
 mv /opt/oracle/client/instantclient_11_2/sdk/ $ORACLE_HOME/ &&\
 rm -R -f /opt/oracle/client/instantclient_11_2/ &&\
 rm -f /opt/oracle/client/instantclient-sdk-linux.x64-11.2.0.4.0.zip &&\
 unzip /opt/oracle/client/instantclient-sqlplus-linux.x64-11.2.0.4.0.zip -d /opt/oracle/client &&\
 mv /opt/oracle/client/instantclient_11_2/* $ORACLE_HOME/ &&\
 rm -R -f /opt/oracle/client/instantclient_11_2/ &&\
 rm -f /opt/oracle/client/instantclient-sqlplus-linux.x64-11.2.0.4.0.zip &&\
 ln -s $ORACLE_HOME/libclntsh.so.11.1 $ORACLE_HOME/libclntsh.so &&\
 ln -s $ORACLE_HOME/libocci.so.11.1 $ORACLE_HOME/libocci.so

FROM php:5.6-fpm-alpine

RUN mkdir -p $ORACLE_HOME/network/admin

COPY --from=OCI_INSTANT_CLIENT /opt/oracle/client/ /opt/oracle/client/

#Instalar glibc para que funcione el InstantClient 11g
ENV ORACLE_HOME=/opt/oracle/client/11.2
ENV LD_LIBRARY_PATH=$ORACLE_HOME
ENV PATH="$ORACLE_HOME:$PATH"

LABEL glibc="Instalación glibc libaio libnsl libzip-dev zip"

RUN apk update &&\
 apk add --no-cache\
 ca-certificates\
 libaio\
 libzip-dev\
 zip\
 libxml2-dev\
 wget &&\
 wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub &&\
 wget https://github.com/sgerrand/alpine-pkg-glibc/releases/download/2.33-r0/glibc-2.33-r0.apk &&\
 apk add --allow-untrusted glibc-2.33-r0.apk &&\
 rm -f glibc-2.33-r0.apk &&\
 ln -s /lib/libc.musl-x86_64.so.1 $ORACLE_HOME/libc.musl-x86_64.so.1 &&\
 ln -s /lib/libkeyutils.so.1 $ORACLE_HOME/libkeyutils.so.1 &&\
 ln -s /lib/libcom_err.so.2 $ORACLE_HOME/libcom_err.so.2 &&\
 ln -s /usr/lib/libgssapi_krb5.so.2 $ORACLE_HOME/libgssapi_krb5.so.2 &&\
 ln -s /usr/lib/libk5crypto.so.3 $ORACLE_HOME/libk5crypto.so.3 &&\
 ln -s /usr/lib/libkrb5support.so.0 $ORACLE_HOME/libkrb5support.so.0 &&\
 ln -s /usr/lib/libkrb5.so.3 $ORACLE_HOME/libkrb5.so.3 &&\
 ln -s /usr/lib/libintl.so.8 $ORACLE_HOME/libintl.so.8 &&\
 ln -s /usr/lib/libtirpc.so.3 $ORACLE_HOME/libtirpc.so.3 &&\
 ln -s /usr/lib/libaio.so.1.0.1 $ORACLE_HOME/libaio.so.1 &&\
 ln -s /usr/glibc-compat/lib/libnsl.so.1 /opt/oracle/client/11.2/libnsl.so.1

# Instalar la libreria OCI8
LABEL oci8="Instalación PHP 5.6 ext OCI8"
RUN \
 docker-php-ext-configure oci8 --with-oci8=instantclient,$ORACLE_HOME &&\
 docker-php-ext-install -j$(nproc) oci8 zip soap &&\
 docker-php-ext-enable oci8 zip soap
