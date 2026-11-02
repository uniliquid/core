FROM php:8.4-cli@sha256:7e7413ed31b8c42b31c939cc83b3758b1cd618f7bf3803f5a0c39f98d4adcbee
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq-dev postgresql-client lua5.1 \
    && docker-php-ext-install pdo_pgsql \
    && rm -rf /var/lib/apt/lists/*
