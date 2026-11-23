# Three targets: build compiles the shared extensions, prod is the image an application serves (no compiler, no
# development tool), and dev, the default target, is prod plus the tools the development images and test suites use.
# Every build argument is required: .github/workflows/build.yml holds the values of each PHP version.

ARG PHP_VERSION

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

# APCu, ssh2 and Xdebug are built the same way on every PHP version: from the archive of a pinned commit, with the
# hardening flags the official image builds its own extensions with.
ARG APCU_COMMIT
RUN set -eux; \
    echo "${APCU_COMMIT:-}" | grep -qxE '[0-9a-f]{40}' || { echo "APCU_COMMIT is not a full commit SHA" >&2; exit 1; }; \
    mkdir /tmp/extension; \
    curl -fsSL -o /tmp/extension.tar.gz "https://github.com/krakjoe/apcu/archive/$APCU_COMMIT.tar.gz"; \
    tar -xzf /tmp/extension.tar.gz -C /tmp/extension --strip-components=1; \
    cd /tmp/extension; \
    phpize; \
    ./configure CFLAGS="$PHP_CFLAGS" CPPFLAGS="$PHP_CPPFLAGS" LDFLAGS="$PHP_LDFLAGS"; \
    make -j"$(nproc)"; \
    make install; \
    cd /; \
    rm -rf /tmp/extension /tmp/extension.tar.gz; \
    docker-php-ext-enable apcu

# The Debian packages the compiled extensions link against, for prod to install without their headers.
RUN set -eu; \
    libraries="$(find "$(php-config --extension-dir)" -name '*.so' -exec ldd {} +)"; \
    if printf '%s\n' "$libraries" | grep -q 'not found'; then printf '%s\n' "$libraries" >&2; exit 1; fi; \
    printf '%s\n' "$libraries" \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
        | sort -u | xargs -r dpkg-query --search | grep -v '^diversion ' | cut -d: -f1 | sort -u > /runtime-packages; \
    test -s /runtime-packages; \
    cat /runtime-packages


FROM php:${PHP_VERSION:?}-apache-bookworm AS prod

# Debian's packages are brought up to date first, so the weekly rebuild takes their security fixes even before the
# official image is rebuilt. No package brings its recommendations along. The compiler the official image keeps for
# phpize ($PHPIZE_DEPS) is removed. libc-dev in that list is virtual, so its package is named.
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
COPY custom.ini /usr/local/etc/php/conf.d/base-custom.ini
COPY php2shell.ini /usr/local/etc/php/conf.d/zz-php2shell.ini

# The build fails if an extension misses a library or PHP complains at startup.
RUN set -eu; \
    libraries="$(find "$(php-config --extension-dir)" -name '*.so' -exec ldd {} +)"; \
    if printf '%s\n' "$libraries" | grep -q 'not found'; then printf '%s\n' "$libraries" >&2; exit 1; fi; \
    modules="$(php -m 2>&1)"; \
    case "$modules" in *Warning*|*Fatal*|*'Unable to load'*) printf '%s\n' "$modules" >&2; exit 1 ;; esac

# Debian's 000-default (DocumentRoot /var/www/html) is disabled and the image's own site enabled in its place, so a
# downstream image can turn either off with a2dissite. mod_status and mod_autoindex are off, their files kept.
COPY vhosts/default.conf /etc/apache2/sites-available/default.conf
RUN set -eu; \
    a2enmod rewrite headers expires; \
    a2dismod -f status autoindex; \
    a2dissite 000-default; \
    a2ensite default

# AllowEncodedSlashes is not inherited from the server config into a <VirtualHost>, so it must sit inside every one,
# or a path holding %2F gets Apache's own 404 before PHP runs. 000-default.conf gets it too, for an image that enables
# it again. The build fails if any enabled <VirtualHost> is left without it.
RUN set -eu; \
    sed -i 's#^\([[:space:]]*<VirtualHost[^>]*>\)[[:space:]]*$#\1\n\tAllowEncodedSlashes NoDecode#' \
        /etc/apache2/sites-available/000-default.conf; \
    total="$(grep -hciE '^[[:space:]]*<VirtualHost[[:space:]>]' /etc/apache2/sites-enabled/*.conf | awk '{n += $1} END {print n + 0}')"; \
    test "$total" -gt 0 || { echo "no <VirtualHost> is enabled" >&2; exit 1; }; \
    for vhost in /etc/apache2/sites-enabled/*.conf /etc/apache2/sites-available/000-default.conf; do \
        vhosts="$(grep -ciE '^[[:space:]]*<VirtualHost[[:space:]>]' "$vhost" || true)"; \
        patched="$(grep -ciE '^[[:space:]]*AllowEncodedSlashes[[:space:]]+NoDecode[[:space:]]*$' "$vhost" || true)"; \
        test "$vhosts" = "$patched" || { echo "$vhost: $vhosts <VirtualHost>, $patched AllowEncodedSlashes NoDecode" >&2; exit 1; }; \
    done; \
    apache2ctl -t

# Debian's security.conf ships ServerTokens OS and ServerSignature On, which name Apache's release and distribution in
# every Server header and error page. They are rewritten in that file, so each has a single value, and the build fails
# unless the enabled configuration holds exactly ServerTokens Prod and ServerSignature Off.
RUN set -eu; \
    sed -i \
        -e 's#^[[:space:]]*ServerTokens[[:space:]].*$#ServerTokens Prod#I' \
        -e 's#^[[:space:]]*ServerSignature[[:space:]].*$#ServerSignature Off#I' \
        /etc/apache2/conf-available/security.conf; \
    active="$(grep -hiE '^[[:space:]]*Server(Tokens|Signature)[[:space:]]' /etc/apache2/apache2.conf \
        /etc/apache2/conf-enabled/*.conf /etc/apache2/sites-enabled/*.conf | sed 's#^[[:space:]]*##; s#[[:space:]]*$##' | sort -u)"; \
    test "$active" = "$(printf 'ServerSignature Off\nServerTokens Prod')" || { echo "Server directives: $active" >&2; exit 1; }; \
    apache2ctl -t

# No TLS in the image: it ends in front of the container, so there is no mod_ssl, no 443 vhost and no private key,
# which anyone pulling this public image would hold. The files of mod_ssl, mod_status and mod_autoindex stay in
# mods-available: `a2dismod ssl` in a downstream image returns 0 on a module already off, but 1 once its files are
# gone. The build fails if any of this changes.
RUN set -eu; \
    test "$(ls -A /etc/apache2/sites-enabled)" = default.conf || { echo "sites-enabled: $(ls -A /etc/apache2/sites-enabled)" >&2; exit 1; }; \
    test -z "$(find /etc/ssl/private -type f)"; \
    for module in ssl status autoindex; do test -e "/etc/apache2/mods-available/$module.load"; done; \
    modules="$(apache2ctl -M 2>/dev/null)"; \
    for module in rewrite headers expires; do \
        printf '%s\n' "$modules" | grep -q " ${module}_module " || { echo "$module is not loaded" >&2; exit 1; }; \
    done; \
    if printf '%s\n' "$modules" | grep -qE ' (ssl|status|autoindex)_module '; then echo "ssl, status or autoindex is loaded" >&2; exit 1; fi

# Debian's locale-gen takes no argument: it builds the locales /etc/locale.gen lists.
RUN set -eu; \
    printf '%s\n' 'en_CA.UTF-8 UTF-8' 'fr_CA.UTF-8 UTF-8' >> /etc/locale.gen; \
    locale-gen

ENV TZ="America/Montreal"

RUN rm -rf /usr/src/*

# No setuid or setgid file: nothing in the image needs to gain privileges.
RUN find / -xdev -perm /6000 -type f -exec chmod ug-s {} +

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

# The headers the extensions of the build stage install, for an extension built against them.
COPY --from=build /usr/local/include/php/ /usr/local/include/php/

RUN curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

RUN gem install mailcatcher --no-document

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Built as APCu is. ssh2 is loaded; Xdebug is compiled but left disabled.
ARG SSH2_COMMIT
ARG XDEBUG_COMMIT
RUN set -eux; \
    echo "${SSH2_COMMIT:-}" | grep -qxE '[0-9a-f]{40}' || { echo "SSH2_COMMIT is not a full commit SHA" >&2; exit 1; }; \
    echo "${XDEBUG_COMMIT:-}" | grep -qxE '[0-9a-f]{40}' || { echo "XDEBUG_COMMIT is not a full commit SHA" >&2; exit 1; }; \
    for source in "php/pecl-networking-ssh2/archive/$SSH2_COMMIT" "xdebug/xdebug/archive/$XDEBUG_COMMIT"; do \
        mkdir /tmp/extension; \
        curl -fsSL -o /tmp/extension.tar.gz "https://github.com/$source.tar.gz"; \
        tar -xzf /tmp/extension.tar.gz -C /tmp/extension --strip-components=1; \
        cd /tmp/extension; \
        phpize; \
        ./configure CFLAGS="$PHP_CFLAGS" CPPFLAGS="$PHP_CPPFLAGS" LDFLAGS="$PHP_LDFLAGS"; \
        make -j"$(nproc)"; \
        make install; \
        cd /; \
        rm -rf /tmp/extension /tmp/extension.tar.gz; \
    done; \
    docker-php-ext-enable ssh2 xdebug; \
    mkdir -p "$PHP_INI_DIR/disabled"; \
    mv "$PHP_INI_DIR/conf.d/docker-php-ext-xdebug.ini" "$PHP_INI_DIR/disabled/"
COPY xdebug.ini /usr/local/etc/php/conf.d/base-xdebug.ini

# The packages above bring setuid files back (crontab): they go, as in prod. The build fails if a tool is missing.
RUN set -eu; \
    find / -xdev -perm /6000 -type f -exec chmod ug-s {} +; \
    php -m | grep -qx ssh2 || { echo "ssh2 is not loaded" >&2; exit 1; }; \
    php -d zend_extension=xdebug.so -v | grep -q 'with Xdebug' || { echo "Xdebug does not load" >&2; exit 1; }; \
    composer --version; \
    git --version; \
    mailcatcher --help > /dev/null

EXPOSE 80 1080
CMD ["/usr/bin/supervisord"]
