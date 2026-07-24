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
RUN printf 'server {\n    listen 8080;\n    server_name _;\n    absolute_redirect off;\n    port_in_redirect off;\n    root /usr/share/nginx/html;\n    index index.html;\n    location / {\n        try_files $uri $uri/ $uri.html =404;\n    }\n}\n' > /etc/nginx/conf.d/default.conf
USER nginx
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
