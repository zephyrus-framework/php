[![Publish](https://github.com/zephyrus-framework/php/actions/workflows/publish.yml/badge.svg)](https://github.com/zephyrus-framework/php/actions/workflows/publish.yml)

# zephyrus-framework/php

The base Docker image of Zephyrus applications: PHP on Apache, Debian Bookworm, built from the official
`php:<version>-apache-bookworm` image. Published as `ghcr.io/zephyrus-framework/php`.

| Tag | Target | For |
|---|---|---|
| `8.4`, `8.6` | `prod` | the image an application serves |
| `8.4-dev`, `8.6-dev` | `dev` | development, test suites, and the build stage of an application image |

Every tag covers amd64 and arm64. `dev` is built on `prod`, so the served image is a subset of the one the test
suites run in.

## `prod`

* PHP and Apache from the official image, without its compiler (`$PHPIZE_DEPS`).
* Extensions built on top of the official ones: APCu, GD (FreeType, JPEG and WebP), exif, gettext, gmp, intl, pcntl,
  pdo_pgsql, pgsql and zip. mbstring too on 8.6, whose official image no longer compiles it in.
* The Debian packages those extensions need at runtime (found by `ldd` at build time), `ca-certificates`, `curl`,
  `locales` and `supervisor`. Supervisor has no program: the application brings its own.
* Apache modules `rewrite`, `headers` and `expires`; `ssl`, `status` and `autoindex` are off.
* Locales `en_CA.UTF-8` and `fr_CA.UTF-8`, time zone `America/Montreal`.
* No setuid or setgid file.
* `CMD ["apache2-foreground"]`, port 80. No `USER`: running as `www-data` is the application's call (see below).

`prod` has no compiler, no `-dev` package, no Composer, no git, no Xdebug, no ssh2, no MailCatcher, no cron, no
`wget`, no SSH client and no mail server (`exim4`, `sendmail`).

## `dev`

Everything in `prod`, plus:

* Composer, git, `build-essential`, phpize's tools and the library headers (`-dev` packages), enough to build another
  extension on top with `phpize`;
* ssh2, loaded;
* Xdebug, compiled but disabled: its ini file waits in `/usr/local/etc/php/disabled/`, and
  `php -d zend_extension=xdebug.so` loads it for one command;
* MailCatcher and cron;
* Supervisor runs Apache, MailCatcher and cron: `CMD ["/usr/bin/supervisord"]`, ports 80 and 1080.

## PHP and Apache configuration

Both targets set (`custom.ini`, `php2shell.ini`):

```ini
apc.enable_cli = 1
session.upload_progress.enabled = 0
session.use_strict_mode = 1
```

`dev` adds `xdebug.ini`, without effect while Xdebug is not loaded:

```ini
[xdebug]
xdebug.output_dir='/xdebug.d'
xdebug.mode = profile
xdebug.use_compression = true
```

Apache, in both targets:

* `AllowEncodedSlashes NoDecode` sits in every enabled `<VirtualHost>`, so a `%2F` in a path reaches PHP instead of
  Apache's own 404. It is not inherited from the server configuration: a vhost a downstream image adds needs the line
  too.
* `ServerTokens Prod` and `ServerSignature Off`: the `Server` header is plain `Apache`.
* No TLS: no `mod_ssl`, no 443 vhost, no private key. TLS ends in front of the container.
* The files of `ssl`, `status` and `autoindex` stay in `mods-available`, so `a2dismod` on them returns 0 in a
  downstream image.

The build fails if any of this stops being true.

## An application image

Dependencies are installed on `8.4-dev`, which has Composer and git; the served image is built on `8.4`, which has
neither.

```dockerfile
FROM ghcr.io/zephyrus-framework/php:8.4-dev AS vendor
WORKDIR /src
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --no-progress --prefer-dist

FROM ghcr.io/zephyrus-framework/php:8.4
COPY . /var/www/html
COPY --from=vendor /src/vendor /var/www/html/vendor
RUN chown root:root /var/www/html && chmod 755 /var/www/html
USER www-data
```

The code belongs to root and the application runs as `www-data`. The official image leaves `/var/www/html` writable by
everyone (1777, owned by `www-data`), hence the `chown` and `chmod`: `www-data` can change nothing there, and the
application opens only the directories it writes to. `www-data` can listen on port 80 because Docker opens the low
ports to every user of a container (`net.ipv4.ip_unprivileged_port_start=0`); a runtime that does not needs a port
above 1024. Leave `vendor/` out of the build context with a `.dockerignore`.

## `check-image.sh`

`./check-image.sh <image>` proves what the `prod` target carries and stops at the first failure: `Cmd` and exposed
ports, no development tool or `-dev` package, no setuid or setgid file, every extension loaded without a warning (and
neither Xdebug nor ssh2), the PHP directives above, the Apache configuration, Supervisor without a program, the
locales, then a real request to Apache. It needs Docker and nothing else, and prints `check-image: PASS` at the end.
The CI runs it on every version and architecture before anything is published.

## Building locally

The build arguments have no default: `prod` needs the first two below, `dev` all four, and the build stops at once when
one is missing (or, for a commit, is not a full SHA). Their values for each PHP version are in the matrix of
[`.github/workflows/build.yml`](.github/workflows/build.yml), the only place they are set.

```sh
docker build --target prod \
  --build-arg PHP_VERSION=<version> \
  --build-arg APCU_COMMIT=<apcu> \
  -t zephyrus-php:8.4 .
./check-image.sh zephyrus-php:8.4

docker build --target dev \
  --build-arg PHP_VERSION=<version> \
  --build-arg APCU_COMMIT=<apcu> \
  --build-arg SSH2_COMMIT=<ssh2> \
  --build-arg XDEBUG_COMMIT=<xdebug> \
  -t zephyrus-php:8.4-dev .
```

## Publishing and the weekly rebuild

* A pull request to `main` builds both versions on both architectures and runs `check-image.sh`; it publishes nothing
  and writes no cache.
* A push to `main` publishes the four tags. Each version and architecture builds `prod`, runs `check-image.sh`, builds
  `dev`, and only then pushes; the multi-arch tags move only once every one of them has passed.
* Every Monday at 07:00 UTC the images are rebuilt without cache, from a fresh pull of the official image, and
  published again: the security fixes of Debian, Apache and the official PHP image reach the tags even when nothing is
  pushed here. A manual run of `Publish` does the same. GitHub suspends a scheduled workflow after 60 days without
  activity in a public repository: turn it back on in the _Actions_ tab if that happens.
* An application takes these fixes when it builds with a fresh pull (`docker build --pull`).

## Migrating from docker-pulsar-php84 / php86

| Before | After |
|---|---|
| `ghcr.io/ophelios-studio/docker-pulsar-php84:latest`, for a development image or a build stage | `ghcr.io/zephyrus-framework/php:8.4-dev` |
| `ghcr.io/ophelios-studio/docker-pulsar-php84:latest`, for the stage that is served | `ghcr.io/zephyrus-framework/php:8.4` |
| `ghcr.io/ophelios-studio/docker-pulsar-php86:latest` | `8.6-dev` and `8.6`, the same way |

What changes for an image built on top:

* `000-default.conf` (DocumentRoot `/var/www/html`) is disabled. Its file stays in `sites-available`, so
  `a2dissite 000-default.conf` still returns 0.
* `default.conf` (DocumentRoot `/var/www/html/public`) is now a site of `sites-available`, enabled with
  `a2ensite default`: an application with its own vhost turns it off with `a2dissite default`.
* No setuid or setgid file (`su`, `passwd`, `mount`, `crontab`...). Installing a package in a derived image can bring
  some back.
* `autoindex` is off: a directory without an index answers 404 instead of listing its files.
* The `en_CA.UTF-8` and `fr_CA.UTF-8` locales are really generated (the old images generated none).
* GD reads and writes WebP and pcntl is loaded, in both targets: a derived image no longer rebuilds gd or adds pcntl.
* `8.4` and `8.6` run `apache2-foreground` alone, on port 80: no Supervisor program, no MailCatcher, no cron. Those
  stay in the `-dev` tags.
* No per-architecture tag to pin: each tag covers amd64 and arm64.

## License

MIT, see [LICENSE](LICENSE).
