FROM php:8.5-cli@sha256:50956f094e90a716d43bea28087d447555ad80510e386ab8c9c10d8c70d781a9
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq-dev postgresql-client lua5.1 \
    && docker-php-ext-install pdo_pgsql \
    && rm -rf /var/lib/apt/lists/*
