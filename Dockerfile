# ---- Stage 1: build ----
FROM node:22-alpine AS build
RUN apk upgrade --no-cache
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- Stage 2: serve (unprivileged, non-root) ----
FROM nginxinc/nginx-unprivileged:alpine
USER root
RUN apk upgrade --no-cache
USER nginx
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
