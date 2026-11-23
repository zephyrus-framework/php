[![Publish](https://github.com/zephyrus-framework/php/actions/workflows/publish.yml/badge.svg)](https://github.com/zephyrus-framework/php/actions/workflows/publish.yml)

# zephyrus-framework/php

The base Docker image of Zephyrus applications: PHP on Apache, Debian 13 (trixie), built from the official
`php:<version>-apache-trixie` image. Published as `ghcr.io/zephyrus-framework/php`.

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
* Apache serves `/var/www/html/public` alone, on port `$APACHE_PORT` (80 by default).
* `/var/www/html` belongs to root (0755), with an empty `public/`.
* Locales `en_CA.UTF-8` and `fr_CA.UTF-8`, time zone `America/Montreal`.
* No setuid or setgid file.
* `CMD ["apache2-foreground"]`, port 80. No `USER`: running as `www-data` is the application's call (see below).

`prod` has no compiler, no `-dev` package, no Composer, no git, no Xdebug, no ssh2, no MailCatcher, no cron, no
`wget`, no SSH client and no mail server (`exim4`, `sendmail`).

## `dev`

Everything in `prod`, plus:

* Composer, git, `build-essential`, phpize's tools, the library headers (`-dev` packages) and the PHP source archive
  (`/usr/src/php.tar.xz`), enough to build another extension on top with `docker-php-ext-install` or `phpize`;
* ssh2, loaded;
* Xdebug, compiled but disabled: its ini file waits in `/usr/local/etc/php/disabled/`, and
  `php -d zend_extension=xdebug.so` loads it for one command;
* MailCatcher, with its dependencies at the versions of [`Gemfile.lock`](Gemfile.lock), and cron;
* Supervisor runs Apache, MailCatcher and cron: `CMD ["/usr/bin/supervisord"]`, ports 80 and 1080.

A `-dev` tag is never served: MailCatcher runs as root with no authentication. Publish its ports on the loopback
alone:

```sh
docker run --rm -p 127.0.0.1:8080:80 -p 127.0.0.1:1080:1080 -v "$PWD":/var/www/html \
  ghcr.io/zephyrus-framework/php:8.4-dev
```

## PHP and Apache configuration

PHP, in both targets: [`custom.ini`](custom.ini) (errors logged and never displayed, no `X-Powered-By`, exception
traces without arguments) and [`php2shell.ini`](php2shell.ini). `dev` adds [`dev.ini`](dev.ini) (traces keep their
arguments) and [`xdebug.ini`](xdebug.ini), without effect while Xdebug is not loaded. They are installed as
`base-*.ini` in `/usr/local/etc/php/conf.d/`, so an application's `zz-*.ini` there overrides any of them.

Apache, in both targets:

* `DocumentRoot /var/www/html/public`, in `default.conf` and in the main server, which answers a port no
  `<VirtualHost>` claims: nothing above `public/` is served. `ServerName localhost`.
* A `.htaccess` is read in `public/` alone (`AllowOverride None` on `/var/www/`, `docker-php.conf` included).
* `Listen ${APACHE_PORT}` in `ports.conf` and `<VirtualHost *:${APACHE_PORT}>` in `default.conf`: an image changes
  the port with `ENV APACHE_PORT=8080`, without editing either file. An application's own vhost is written
  `<VirtualHost *:${APACHE_PORT}>`: one left on `*:80` is ignored without a warning once the port changes, and the main
  server answers in its place, without the vhost's access rules, headers and log.
* `AllowEncodedSlashes NoDecode` sits in every enabled `<VirtualHost>`, so a `%2F` in a path reaches PHP instead of
  Apache's own 404. It is not inherited from the server configuration: a vhost a downstream image adds needs the line
  too.
* `ServerTokens Prod` and `ServerSignature Off`: the `Server` header is plain `Apache`.
* No TLS: no `mod_ssl`, no 443 vhost, no private key. TLS ends in front of the container.
* The files of `ssl`, `status` and `autoindex` stay in `mods-available`, so `a2dismod` on them returns 0 in a
  downstream image.

The build and `check-image.sh` between them fail if any of this stops being true.

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
RUN find /var/www/html -perm /022 -exec chmod go-w {} +
USER www-data
```

The code belongs to root and the application runs as `www-data`: `/var/www/html` stays root's (0755) through the
`COPY` and the `chmod` strips write access a lax build context (a working copy made under `umask 000`) would carry in,
so `www-data` can change nothing there, and the application opens only the directories it writes to.
`www-data` can listen on port 80 because Docker opens the low ports to every user of a container
(`net.ipv4.ip_unprivileged_port_start=0`). A runtime that does not (one that runs the image as `www-data` outside
Docker Engine) needs `ENV APACHE_PORT=8080` in the image, and its proxy pointed at port 8080. Leave `vendor/` out of
the build context with a `.dockerignore`.

## `check-image.sh`

`./check-image.sh <image>` checks what the `prod` target carries, as root, and stops at the first failure: `Cmd` and
exposed ports, no development tool or `-dev` package, no setuid or setgid file, no file capability, no private key in
`/etc`, `/root`, `/usr/local` or `/var`, every extension loaded without a warning (and neither Xdebug nor ssh2), the Apache modules
against an allowlist, `ServerTokens`, `ServerSignature` and `TraceEnable`, the main `DocumentRoot`, the owner of
`/var/www/html` and `public/`, any `Alias` or `Listen` beyond `/icons/` and `$APACHE_PORT`, Supervisor without a program, the locales. It then asks Apache itself, on port `$APACHE_PORT` and on
a port no vhost claims, for the PHP version and directives it serves, its headers, which `.htaccess` it reads, a file
outside `public/` and `TRACE`. It needs Docker and nothing else, and prints `check-image: PASS` at the end. It catches
the regressions it looks for; it is no proof that an image is safe. The CI runs it on every version and architecture
before anything is published.

## Building locally

The build arguments have no default: `prod` needs the first two below, `dev` all four, and the build stops at once when
one is missing (or, for a commit, is not a full SHA). `PHP_VERSION` is the minor version (`8.4`), the tag of the
official image to build on. Their values for each PHP version are in the matrix of
[`.github/workflows/build.yml`](.github/workflows/build.yml), the only place they are set.

```sh
docker build --target prod \
  --build-arg PHP_VERSION=8.4 \
  --build-arg APCU_COMMIT=<apcu> \
  -t zephyrus-php:8.4 .
./check-image.sh zephyrus-php:8.4

docker build --target dev \
  --build-arg PHP_VERSION=8.4 \
  --build-arg APCU_COMMIT=<apcu> \
  --build-arg SSH2_COMMIT=<ssh2> \
  --build-arg XDEBUG_COMMIT=<xdebug> \
  -t zephyrus-php:8.4-dev .
```

## Publishing and the weekly rebuild

* A pull request to `main` builds both versions on both architectures and runs `check-image.sh`; it publishes nothing
  and writes no cache.
* A push to `main` publishes the four tags. Each version and architecture builds `prod`, runs `check-image.sh`, builds
  `dev`, and only then pushes both by digest. A version's two tags move only once both of its architectures have
  passed in that run; the versions are independent, so a failing 8.6 never holds 8.4 back.
* Every Monday at 07:00 UTC the images are rebuilt without cache, from a fresh pull of the official image, and
  published again: each tag takes the latest PHP patch the official image has released for its minor version, and the
  security fixes of Debian and Apache, even when nothing is pushed here. A manual run of `Publish` does the same.
  GitHub suspends a scheduled workflow after 60 days without activity in a public repository: turn it back on in the
  _Actions_ tab if that happens.
* An application takes these fixes when it builds with a fresh pull (`docker build --pull`).
* The `cache-*` tags are the build cache of the CI, not images to pull.

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
* `/var/www/html` belongs to root (0755) in both targets: an application image no longer needs its own `chown` and
  `chmod`.
* A `.htaccess` above `public/` is no longer read.
* The base sets the PHP error directives each application used to set itself ([`custom.ini`](custom.ini)): its own
  `zz-*.ini` can drop them, and still overrides the base. `-dev` displays no error either (the old image had no
  `php.ini`, so `display_errors` was on), and keeps the arguments in exception traces.
* A different port is `ENV APACHE_PORT=<port>`, not an edit of `ports.conf` and the vhost, and an application's own
  vhost is written `<VirtualHost *:${APACHE_PORT}>`: one left on `*:80` is ignored without a warning once the port
  changes, and the main server answers in its place.
* `autoindex` is off: a directory without an index answers 404 instead of listing its files.
* The `en_CA.UTF-8` and `fr_CA.UTF-8` locales are really generated (the old images generated none).
* GD reads and writes WebP and pcntl is loaded, in both targets: a derived image no longer rebuilds gd or adds pcntl.
* `8.4` and `8.6` run `apache2-foreground` alone, on port 80: no Supervisor program, no MailCatcher, no cron. Those
  stay in the `-dev` tags.
* No per-architecture tag: each tag covers amd64 and arm64.

## Moving to Debian 13 (trixie)

The tags `8.4`, `8.4-dev`, `8.6` and `8.6-dev` moved from Debian 12 (bookworm) to Debian 13 (trixie). An application
picks the change up at its next build on the same tags (`docker build --pull`). What changes:

* glibc 2.41 instead of 2.36, ICU 76 instead of 72, OpenSSL 3.5 instead of 3.0, and Ruby 3.3 instead of 3.1 in `-dev`.
* Locale data follows ICU 76. Run the application's formatting tests. Time zone names in the `FULL` and `LONG` date
  styles change for some zones: in `America/Montreal`, `UTC−04:00` becomes `heure avancée de l’Est` (`fr_CA`) and
  `GMT-4` becomes `EDT` (`en_CA`), while `America/Toronto` and `UTC` do not change. The `SHORT` style of `en_CA` becomes
  `2026-03-07`, and `localeconv()` reports a `mon_grouping` of `[3]` instead of `[3,3]`. Number formats and the
  `Collator` order are unchanged.
* `pdo_pgsql` and `pgsql` link `libpq` 17 (bookworm: 15). Debian 13 ships `postgresql-17` and its client: a derived
  image installs them without the PGDG repository.
* MailCatcher is 0.11.0, installed with `bundle3.3`.
* Some `apt` packages were renamed. A derived image that installs one of the old names fails to build:

| Bookworm | Trixie |
|---|---|
| `libcurl4` | `libcurl4t64` |
| `libssh2-1` | `libssh2-1t64` |
| `libfreetype6-dev` | `libfreetype-dev` |
| `rubygems` | `ruby-rubygems` (installed with `ruby-dev`), and `bundler` for the `bundle` command |

To stay on Debian 12, pin the digest of the bookworm image in the `FROM` line, for example
`ghcr.io/zephyrus-framework/php:8.4@sha256:...`:

| Tag | Bookworm digest |
|---|---|
| `8.4` | `sha256:acfbe0dcad654baec96bf0dbfddd70dc9aa3563e2d838e4681a631de2cf59a4b` |
| `8.4-dev` | `sha256:4bd0b1e4acb246ac111b7bc1f653f77194b3dbd4877ab4551af1f47124e4c99d` |
| `8.6` | `sha256:15abcdfe719275caf35caacc2a1492a28b1c647935e713ec4ada181764b8d3ad` |
| `8.6-dev` | `sha256:882671019bab875d2e2ae0bf6a15b9a4726fe1d42f3e0db4e5d6ea5cb704731b` |

A pinned digest gets no further Debian or PHP security fix: use it as a short stop while the application is fixed, not
as a place to stay.

## License

MIT, see [LICENSE](LICENSE).
