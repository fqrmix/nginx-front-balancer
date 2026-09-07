FROM nginx:1.27-alpine

COPY conf.d/ /etc/nginx/conf.d/
COPY docker-entrypoint-reload.sh /docker-entrypoint-reload.sh
RUN chmod +x /docker-entrypoint-reload.sh

CMD ["/docker-entrypoint-reload.sh"]
