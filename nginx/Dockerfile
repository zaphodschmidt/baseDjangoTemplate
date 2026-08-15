# The production edge: builds the frontend, then serves it and proxies the API.
#
# Build context is the REPO ROOT (see docker-compose.prod.yml), because this
# image needs both frontend/ and nginx/. One image rather than two services
# means the static assets and the routing that serves them are versioned and
# deployed together — a frontend built against one set of routes cannot be
# served by an edge configured for another.

FROM node:22.14.0-alpine AS build
WORKDIR /app
RUN npm install -g pnpm@10

COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY frontend/ ./

# Anything VITE_-prefixed is inlined into the bundle and ships to every visitor.
# Only non-secret configuration belongs here — and only values named one at a
# time, never the whole build environment.
ARG VITE_API_BASE_URL=""
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL

RUN pnpm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx/default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
