FROM php:7-fpm

# Install libs
RUN apt update && DEBIAN_FRONTEND=noninteractive apt install -y \
  git \
  openssl \ 
  libfreetype-dev \
  libjpeg62-turbo-dev \
  libpng-dev \
  libzip-dev \
  libxml2-dev \
  && apt clean

# Install PHP extensions
RUN pecl install mongodb zip \
  && docker-php-ext-enable mongodb zip \
  && docker-php-ext-configure gd --with-freetype --with-jpeg \
  && docker-php-ext-install -j$(nproc) gd soap pcntl intl sockets pdo pdo_mysql

# Install php compose
COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

RUN mkdir ~/.ssh && chmod -R 0600 ~/.ssh
RUN mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"

COPY docker-entrypoint.d /docker-entrypoint.d
COPY docker-php-entrypoint.sh /docker-php-entrypoint.sh

WORKDIR /opt/project

ENTRYPOINT ["/docker-php-entrypoint.sh"]
CMD ["php-fpm"]