FROM nginx:alpine
RUN mkdir -p /var/www/data /var/www/logs /var/www/report
COPY docker/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY docker/web/index.html /var/www/index.html
