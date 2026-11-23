# Three targets: build compiles the shared extensions, prod is the image an application serves (no compiler, no
# development tool), and dev, the default target, is prod plus the development tools. Every build argument is
# required: .github/workflows/build.yml holds the values of each PHP version.

ARG PHP_VERSION

FROM composer/composer:2.11.2-bin@sha256:4eaf89f62eb9504807f2828f1829a71b7fcd202e89abe2f41c1fb2136068fbfb AS composer


FROM php:${PHP_VERSION:?}-apache-bookworm AS build

# From PHP 8.6 on, the official image no longer compiles mbstring in: it is built wherever PHP lacks it.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libfreetype6-dev libgmp-dev libicu-dev libjpeg62-turbo-dev libonig-dev libpng-dev libpq-dev libwebp-dev \
        libzip-dev zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*; \
    docker-php-ext-configure gd --enable-gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" exif gd gettext gmp intl pcntl pdo_pgsql pgsql zip; \
    php -r 'exit(extension_loaded("mbstring") ? 0 : 1);' || docker-php-ext-install -j"$(nproc)" mbstring

ARG APCU_COMMIT
RUN --mount=type=bind,source=build-extension.sh,target=/usr/local/bin/build-extension.sh \
    set -eux; \
    build-extension.sh krakjoe/apcu "$APCU_COMMIT"; \
    docker-php-ext-enable apcu

# The Debian packages the compiled extensions link against, for prod to install without their headers.
RUN set -eu; \
    libraries="$(find "$(php-config --extension-dir)" -name '*.so' -exec ldd {} +)"; \
    printf '%s\n' "$libraries" \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
        | sort -u | xargs -r dpkg-query --search | grep -v '^diversion ' | cut -d: -f1 | sort -u > /runtime-packages; \
    test -s /runtime-packages; \
    cat /runtime-packages


FROM php:${PHP_VERSION:?}-apache-bookworm AS prod

# apt-get upgrade takes Debian's fixes before the official image is rebuilt. The compiler the official image keeps
# for phpize ($PHPIZE_DEPS) goes; libc-dev in that list is virtual, so its package is named.
COPY --from=build /runtime-packages /tmp/runtime-packages
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold; \
    DEBIAN_FRONTEND=noninteractive xargs -a /tmp/runtime-packages \
        apt-get install -y --no-install-recommends ca-certificates curl locales supervisor; \
    DEBIAN_FRONTEND=noninteractive apt-get purge -y --auto-remove $PHPIZE_DEPS libc6-dev; \
    rm -rf /var/lib/apt/lists/* /tmp/runtime-packages

COPY --from=build /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=build /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/
# Named base-*.ini, so an application's zz-*.ini comes after them and wins.
COPY custom.ini /usr/local/etc/php/conf.d/base-custom.ini
COPY php2shell.ini /usr/local/etc/php/conf.d/base-php2shell.ini

# The build fails if an extension misses a library or PHP complains at startup.
RUN set -eu; \
    libraries="$(find "$(php-config --extension-dir)" -name '*.so' -exec ldd {} +)"; \
    if printf '%s\n' "$libraries" | grep -q 'not found'; then printf '%s\n' "$libraries" >&2; exit 1; fi; \
    modules="$(php -m 2>&1)"; \
    case "$modules" in *Warning*|*Fatal*|*'Unable to load'*) printf '%s\n' "$modules" >&2; exit 1 ;; esac

ENV APACHE_PORT=80

# Apache serves public/ alone, on $APACHE_PORT, and reads a .htaccess in public/ alone. The official docker-php.conf
# allows overrides on all of /var/www/: they are turned off there.
COPY server.conf /etc/apache2/conf-available/server.conf
COPY vhosts/default.conf /etc/apache2/sites-available/default.conf
RUN set -eu; \
    mkdir /var/www/html/public; \
    sed -i 's#^Listen 80$#Listen ${APACHE_PORT}#' /etc/apache2/ports.conf; \
    grep -qx 'Listen ${APACHE_PORT}' /etc/apache2/ports.conf || { echo "ports.conf: no Listen 80 to replace" >&2; exit 1; }; \
    sed -i 's#^\([[:space:]]*AllowOverride\)[[:space:]][[:space:]]*All[[:space:]]*$#\1 None#' /etc/apache2/conf-available/docker-php.conf; \
    if grep -qiE '^[[:space:]]*AllowOverride[[:space:]]+All' /etc/apache2/conf-available/docker-php.conf; then \
        echo "docker-php.conf still allows overrides" >&2; exit 1; \
    fi; \
    a2enmod rewrite headers expires; \
    a2dismod -f status autoindex; \
    a2dissite 000-default; \
    a2ensite default; \
    a2enconf server

# AllowEncodedSlashes is not inherited into a <VirtualHost>: every enabled one carries it, and 000-default.conf too,
# for an image that enables it again.
RUN set -eu; \
    sed -i 's#^\([[:space:]]*<VirtualHost[^>]*>\)[[:space:]]*$#\1\n\tAllowEncodedSlashes NoDecode#' \
        /etc/apache2/sites-available/000-default.conf; \
    total="$(grep -hciE '^[[:space:]]*<VirtualHost[[:space:]>]' /etc/apache2/sites-enabled/*.conf | awk '{n += $1} END {print n + 0}')"; \
    test "$total" -gt 0 || { echo "no <VirtualHost> is enabled" >&2; exit 1; }; \
    for vhost in /etc/apache2/sites-enabled/*.conf /etc/apache2/sites-available/000-default.conf; do \
        vhosts="$(grep -ciE '^[[:space:]]*<VirtualHost[[:space:]>]' "$vhost" || true)"; \
        patched="$(grep -ciE '^[[:space:]]*AllowEncodedSlashes[[:space:]]+NoDecode[[:space:]]*$' "$vhost" || true)"; \
        test "$vhosts" = "$patched" || { echo "$vhost: $vhosts <VirtualHost>, $patched AllowEncodedSlashes NoDecode" >&2; exit 1; }; \
    done

# ServerTokens Prod and ServerSignature Off, as the only values of the enabled configuration.
RUN set -eu; \
    sed -i \
        -e 's#^[[:space:]]*ServerTokens[[:space:]].*$#ServerTokens Prod#I' \
        -e 's#^[[:space:]]*ServerSignature[[:space:]].*$#ServerSignature Off#I' \
        /etc/apache2/conf-available/security.conf; \
    active="$(grep -hiE '^[[:space:]]*Server(Tokens|Signature)[[:space:]]' /etc/apache2/apache2.conf \
        /etc/apache2/conf-enabled/*.conf /etc/apache2/sites-enabled/*.conf | sed 's#^[[:space:]]*##; s#[[:space:]]*$##' | sort -u)"; \
    test "$active" = "$(printf 'ServerSignature Off\nServerTokens Prod')" || { echo "Server directives: $active" >&2; exit 1; }

# No TLS, so no private key a public image would give away. The files of ssl, status and autoindex stay in
# mods-available: a2dismod returns 1 on a module whose files are gone.
RUN set -eu; \
    test "$(ls -A /etc/apache2/sites-enabled)" = default.conf || { echo "sites-enabled: $(ls -A /etc/apache2/sites-enabled)" >&2; exit 1; }; \
    test -z "$(find /etc/ssl/private -type f)"; \
    for module in ssl status autoindex; do test -e "/etc/apache2/mods-available/$module.load"; done; \
    modules="$(apache2ctl -M 2>/dev/null)"; \
    for module in rewrite headers expires; do \
        printf '%s\n' "$modules" | grep -q " ${module}_module " || { echo "$module is not loaded" >&2; exit 1; }; \
    done; \
    if printf '%s\n' "$modules" | grep -qE ' (ssl|status|autoindex)_module '; then echo "ssl, status or autoindex is loaded" >&2; exit 1; fi; \
    syntax="$(apache2ctl -t 2>&1)"; \
    test "$syntax" = 'Syntax OK' || { echo "apache2ctl -t: $syntax" >&2; exit 1; }

# Debian's locale-gen takes no argument: it builds the locales /etc/locale.gen lists.
RUN set -eu; \
    printf '%s\n' 'en_CA.UTF-8 UTF-8' 'fr_CA.UTF-8 UTF-8' >> /etc/locale.gen; \
    locale-gen

ENV TZ="America/Montreal"

# The application root belongs to root, not to www-data (the official image leaves it 1777). No setuid or setgid
# file: nothing in the image needs to gain privileges.
RUN set -eu; \
    chown root:root /var/www/html; \
    chmod 755 /var/www/html; \
    rm -rf /usr/src/*; \
    find / -xdev -perm /6000 -type f -exec chmod ug-s {} +

EXPOSE 80
CMD ["apache2-foreground"]


FROM prod AS dev

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PHPIZE_DEPS \
        apt-utils gnupg lsb-release ca-certificates wget build-essential cron git curl zip unzip openssl dialog locales \
        libonig-dev libcurl4 libcurl4-openssl-dev supervisor libsqlite3-dev libsqlite3-0 zlib1g-dev libzip-dev libpq-dev \
        libicu-dev libfreetype6-dev libjpeg62-turbo-dev libpng-dev libxml2-dev libssh2-1 libssh2-1-dev libgmp-dev \
        rubygems ruby-dev sqlite3; \
    rm -rf /var/lib/apt/lists/*

# The PHP source archive and headers, for docker-php-ext-install and phpize to build another extension.
COPY --from=build /usr/src/ /usr/src/
COPY --from=build /usr/local/include/php/ /usr/local/include/php/

COPY --from=composer /composer /usr/local/bin/composer

# MailCatcher and its dependencies, each at the version Gemfile.lock fixes (0.11 needs Ruby 3.3; Bookworm ships 3.1).
RUN --mount=type=bind,source=Gemfile,target=/tmp/mailcatcher/Gemfile \
    --mount=type=bind,source=Gemfile.lock,target=/tmp/mailcatcher/Gemfile.lock \
    BUNDLE_GEMFILE=/tmp/mailcatcher/Gemfile BUNDLE_FROZEN=true bundle3.1 install

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# ssh2 is loaded; Xdebug is compiled but left disabled.
ARG SSH2_COMMIT
ARG XDEBUG_COMMIT
RUN --mount=type=bind,source=build-extension.sh,target=/usr/local/bin/build-extension.sh \
    set -eux; \
    build-extension.sh php/pecl-networking-ssh2 "$SSH2_COMMIT"; \
    build-extension.sh xdebug/xdebug "$XDEBUG_COMMIT"; \
    docker-php-ext-enable ssh2 xdebug; \
    mkdir -p "$PHP_INI_DIR/disabled"; \
    mv "$PHP_INI_DIR/conf.d/docker-php-ext-xdebug.ini" "$PHP_INI_DIR/disabled/"
COPY dev.ini /usr/local/etc/php/conf.d/base-dev.ini
COPY xdebug.ini /usr/local/etc/php/conf.d/base-xdebug.ini

# The packages above bring setuid files back (crontab): they go, as in prod. The build fails if a tool is missing.
RUN set -eu; \
    find / -xdev -perm /6000 -type f -exec chmod ug-s {} +; \
    php -m | grep -qx ssh2 || { echo "ssh2 is not loaded" >&2; exit 1; }; \
    php -d zend_extension=xdebug.so -v | grep -q 'with Xdebug' || { echo "Xdebug does not load" >&2; exit 1; }; \
    test -s /usr/src/php.tar.xz || { echo "/usr/src/php.tar.xz is missing" >&2; exit 1; }; \
    composer --version; \
    git --version; \
    mailcatcher --help > /dev/null; \
    php -r 'exit(filter_var(ini_get("zend.exception_ignore_args"), FILTER_VALIDATE_BOOLEAN) ? 1 : 0);' || { echo "dev.ini does not override custom.ini" >&2; exit 1; }

EXPOSE 80 1080
CMD ["/usr/bin/supervisord"]
