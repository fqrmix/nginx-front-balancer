FROM nginx:1.27-alpine

RUN apk add --no-cache iproute2

COPY conf.d/ /etc/nginx/conf.d/
COPY docker-entrypoint-reload.sh /docker-entrypoint-reload.sh
RUN chmod +x /docker-entrypoint-reload.sh

CMD ["/docker-entrypoint-reload.sh"]
