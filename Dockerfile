FROM nginx:stable-alpine

# BACKEND_HOST is set by the ECS task definition (or Docker Compose locally).
ENV BACKEND_HOST=backend:8000

COPY index.html /usr/share/nginx/html/index.html
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 80
