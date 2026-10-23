FROM node:24-alpine AS build
WORKDIR /site
COPY package*.json ./
RUN npm ci
COPY index.html admin.html vite.config.js ./
COPY src ./src
COPY public ./public
RUN npm run build

FROM nginxinc/nginx-unprivileged:stable-alpine
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /site/dist /usr/share/nginx/html
EXPOSE 8080
