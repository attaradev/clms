FROM nginx:stable-alpine

ARG UID=1000
ARG GID=1000
ARG USER=app

ENV UID=${UID}
ENV GID=${GID}
ENV USER=${USER}

# Align nginx worker user
RUN delgroup dialout || true \
    && addgroup -g ${GID} --system ${USER} \
    && adduser -G ${USER} --system -D -s /bin/sh -u ${UID} ${USER} \
    && sed -i "s/user  nginx/user ${USER}/g" /etc/nginx/nginx.conf

# Nginx config
ADD ./dockerfiles/nginx/default.conf /etc/nginx/conf.d/

WORKDIR /var/www/html

# Copy only public assets (index.php, docs, images, etc.)
COPY public/ ./public/

RUN mkdir -p /var/www/html

EXPOSE 80

