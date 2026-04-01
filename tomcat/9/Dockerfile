FROM alpine:latest AS tomcat-jru

COPY ./webapp/tomcat9.7z /home/

RUN apk update && apk add --no-cache p7zip && \
  7z x /home/tomcat9.7z -o/home/ && \
  rm /home/tomcat9.7z

FROM tomcat:alpine

# paquetes en la imagen final por sí sola)
RUN apk update && apk add --no-cache php-cgi

# Copiar resto de Tomcat (si el artefacto extraído contiene la instalación)
COPY --from=tomcat-jru /home/tomcat9/usr/local/tomcat/ /usr/local/tomcat/

