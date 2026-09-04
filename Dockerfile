# Railway-friendly OpenFront build (no BuildKit cache mounts).
FROM node:24-slim AS base
WORKDIR /usr/src/app

FROM base AS build
ENV HUSKY=0
ENV NODE_OPTIONS=--max-old-space-size=4096
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY vite.config.ts ./
COPY eslint.config.js ./
COPY index.html ./
COPY client-api.json ./
COPY resources ./resources
COPY proprietary ./proprietary
COPY src ./src
COPY zbin ./zbin
COPY scripts ./scripts
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT="$GIT_COMMIT"
RUN npm run build-prod

FROM base AS prod-deps
ENV HUSKY=0
ENV NPM_CONFIG_IGNORE_SCRIPTS=1
COPY package*.json ./
RUN npm ci --omit=dev

FROM base
RUN apt-get update && apt-get install -y \
    nginx \
    curl \
    wget \
    supervisor \
    apache2-utils \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i 's/worker_connections [0-9]*/worker_connections 8192/' /etc/nginx/nginx.conf

RUN mkdir -p /var/log/supervisor
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
# Debian nginx ships a default site that also claims default_server on :80
RUN rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default \
 && rm -f /etc/nginx/conf.d/default.conf \
 && printf 'server_names_hash_bucket_size 128;\n' > /etc/nginx/conf.d/00-defaults.conf
COPY nginx.conf /etc/nginx/conf.d/openfront.conf

COPY generate-nginx-upstream.sh /usr/local/bin/generate-nginx-upstream.sh
RUN chmod +x /usr/local/bin/generate-nginx-upstream.sh

COPY --from=prod-deps /usr/src/app/node_modules ./node_modules
COPY package*.json ./
COPY --from=build /usr/src/app/static ./static
COPY resources ./resources
RUN rm -rf ./resources/maps
COPY tsconfig.json ./
COPY client-api.json ./
COPY src ./src
COPY zbin ./zbin

ARG GIT_COMMIT=unknown
RUN echo "$GIT_COMMIT" > static/commit.txt
ENV GIT_COMMIT="$GIT_COMMIT"

RUN printf '%s\n' \
  '#!/bin/sh' \
  '/usr/local/bin/generate-nginx-upstream.sh' \
  'if [ "$DOMAIN" = openfront.dev ] && [ "$SUBDOMAIN" != main ]; then' \
  '  exec timeout 25h /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf' \
  'else' \
  '  exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf' \
  'fi' \
  > /usr/local/bin/start.sh \
  && chmod +x /usr/local/bin/start.sh

ENV GAME_ENV=dev
ENV NUM_WORKERS=2
ENV DOMAIN=localhost
ENV GIT_COMMIT=selfhost
ENV TURNSTILE_SITE_KEY=1x00000000000000000000AA
ENV API_KEY=WARNING_DEV_API_KEY_DO_NOT_USE_IN_PRODUCTION
ENV ADMIN_BOT_API_KEY=WARNING_DEV_ADMIN_BOT_KEY_DO_NOT_USE_IN_PRODUCTION
EXPOSE 80
ENTRYPOINT ["/usr/local/bin/start.sh"]
