FROM python:3.13-alpine AS pip_reqs

RUN mkdir -p /app

COPY ./requirements/* /app

RUN apk update && apk add --no-cache \
  autoconf \
  automake \
  gcc \
  g++ \
  gcompat \
  make \
  linux-headers \
  libaio \
  libnsl \
  postgresql-dev \
  openldap-dev

RUN pip install -r /app/requirements-dev.txt

FROM python:3.13-alpine

COPY --from=pip_reqs /root/.cache/pip /root/.cache/pip
COPY --from=pip_reqs /usr/local/lib/python3.13/site-packages /usr/local/lib/python3.13/site-packages

WORKDIR /app