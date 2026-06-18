FROM alpine:latest AS tomcat-jru

COPY ./webapp/tomcat9.7z /home/

RUN apk update && apk add --no-cache p7zip && \
  7z x /home/tomcat9.7z -o/home/ && \
  rm /home/tomcat9.7z

FROM tomcat:alpine

# paquetes en la imagen final por sí sola)
RUN apk update && apk add --no-cache \
  php-cgi \
  fontconfig \
  ttf-dejavu

# Copiar resto de Tomcat (si el artefacto extraído contiene la instalación)
COPY --from=tomcat-jru /home/tomcat9/usr/local/tomcat/ /usr/local/tomcat/

# Copy fonts folder from build context. Place your fonts (ttf/otf) or archives (zip, tar.gz, 7z) into a local
# `fonts/` directory next to this Dockerfile before building.
COPY fonts /tmp/fonts

# Extract compressed fonts, copy ttf/otf files into system fonts and update font cache.
# Installs small helper packages only for extraction, then removes them to keep image slim.
RUN if [ -d /tmp/fonts ]; then \
      mkdir -p /usr/share/fonts/truetype/custom && \
      apk add --no-cache unzip p7zip && \
      for f in /tmp/fonts/*; do \
        case "$f" in \
          *.zip) unzip -o "$f" -d /usr/share/fonts/truetype/custom ;; \
          *.tar.gz|*.tgz) tar -xzf "$f" -C /usr/share/fonts/truetype/custom ;; \
          *.tar.bz2|*.tbz2) tar -xjf "$f" -C /usr/share/fonts/truetype/custom ;; \
          *.7z) 7z x "$f" -o/usr/share/fonts/truetype/custom ;; \
          *.ttf|*.otf) cp "$f" /usr/share/fonts/truetype/custom/ ;; \
          *) echo "Skipping $f" ;; \
        esac; \
      done && \
      fc-cache -f -v && \
      rm -rf /tmp/fonts && \
      apk del p7zip unzip; \
    fi

