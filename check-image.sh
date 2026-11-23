#!/bin/sh
# Proves what the prod target carries and stops at the first failure: ./check-image.sh <image>
set -eu

[ "$#" -eq 1 ] || { echo "usage: $0 <image>" >&2; exit 2; }
image=$1

fail() { echo "check-image: FAIL: $*" >&2; exit 1; }
pass() { echo "check-image: ok    $*"; }

cmd=$(docker image inspect -f '{{json .Config.Cmd}}' "$image") || fail "no image $image"
[ "$cmd" = '["apache2-foreground"]' ] || fail "Cmd is $cmd, not [\"apache2-foreground\"]"
ports=$(docker image inspect -f '{{range $port, $_ := .Config.ExposedPorts}}{{$port}} {{end}}' "$image")
[ "$ports" = '80/tcp ' ] || fail "the exposed ports are $ports, not 80/tcp alone"
pass "Cmd is apache2-foreground, 80/tcp is the one exposed port"

docker run --rm -i --entrypoint sh "$image" -s <<'INSIDE'
set -u

fail() { echo "check-image: FAIL: $*" >&2; exit 1; }
pass() { echo "check-image: ok    $*"; }
on() { php -r 'exit(filter_var(ini_get($argv[1]), FILTER_VALIDATE_BOOLEAN) ? 0 : 1);' "$1"; }

tools="composer git ssh scp sftp gcc cc g++ c++ make ruby gem mailcatcher cron crontab exim4 sendmail wget"
for binary in $tools; do
    found=$(command -v "$binary") && fail "$binary is installed at $found"
done
packages=$(dpkg-query -W -f '${Package}\n' | grep -E -- '-dev(:|$)')
[ -z "$packages" ] || fail "development packages are installed: $packages"
pass "none of $tools, and no -dev package"

setid=$(find / -xdev -perm /6000 -type f 2>/dev/null)
[ -z "$setid" ] || fail "setuid or setgid files: $setid"
pass "no setuid or setgid file"

modules=$(php -m 2>&1) || fail "php -m failed: $modules"
case "$modules" in *Warning*|*Fatal*|*'Unable to load'*) fail "php -m complains: $modules" ;; esac
for module in apcu Core ctype curl date dom exif fileinfo filter gd gettext gmp hash iconv intl json libxml mbstring \
    mysqlnd openssl pcntl pcre PDO pdo_pgsql pdo_sqlite pgsql Phar posix random readline Reflection session SimpleXML \
    sodium SPL sqlite3 standard tokenizer xml xmlreader xmlwriter 'Zend OPcache' zip zlib; do
    printf '%s\n' "$modules" | grep -qxF "$module" || fail "the $module module is not loaded"
done
php -r '$gd = gd_info(); exit($gd["WebP Support"] && $gd["JPEG Support"] && $gd["FreeType Support"] ? 0 : 1);' \
    || fail "gd lacks WebP, JPEG or FreeType: $(php -r 'var_export(gd_info());')"
for module in xdebug ssh2; do
    printf '%s\n' "$modules" | grep -qix "$module" && fail "the $module module is loaded"
done
compiled=$(find /usr/local/lib/php -name xdebug.so -o -name ssh2.so)
[ -z "$compiled" ] || fail "an xdebug or ssh2 extension is on disk: $compiled"
named=$(grep -rli xdebug "$PHP_INI_DIR")
[ -z "$named" ] || fail "a file of $PHP_INI_DIR names xdebug: $named"
pass "php -m is clean, every module is loaded with pcntl, gd has WebP, JPEG and FreeType, no xdebug or ssh2"

on session.use_strict_mode || fail "session.use_strict_mode is off"
on session.upload_progress.enabled && fail "session.upload_progress.enabled is on"
on apc.enable_cli || fail "apc.enable_cli is off"
pass "session.use_strict_mode on, session.upload_progress.enabled off, apc.enable_cli on"

apache2ctl -t >/dev/null 2>&1 || fail "apache2ctl -t: $(apache2ctl -t 2>&1)"
loaded=$(apache2ctl -M 2>/dev/null)
for module in rewrite headers expires; do
    printf '%s\n' "$loaded" | grep -q " ${module}_module " || fail "Apache does not load $module"
done
for module in ssl status autoindex; do
    printf '%s\n' "$loaded" | grep -q " ${module}_module " && fail "Apache loads $module"
    [ -e "/etc/apache2/mods-available/$module.load" ] || fail "$module.load is gone from mods-available"
done
sites=$(ls -A /etc/apache2/sites-enabled)
[ "$sites" = default.conf ] || fail "sites-enabled holds $sites, not default.conf alone"
keys=$(find /etc/ssl/private -type f 2>/dev/null)
[ -z "$keys" ] || fail "a private key is in the image: $keys"
active=$(grep -hiE '^[[:space:]]*Server(Tokens|Signature)[[:space:]]' /etc/apache2/apache2.conf \
    /etc/apache2/conf-enabled/*.conf /etc/apache2/sites-enabled/*.conf | sed 's#^[[:space:]]*##; s#[[:space:]]*$##' | sort -u)
[ "$active" = "$(printf 'ServerSignature Off\nServerTokens Prod')" ] || fail "the Server directives are: $active"
pass "Apache: rewrite, headers and expires loaded, no ssl, status or autoindex (files kept), default.conf alone, no key, ServerTokens Prod, ServerSignature Off"

command -v supervisord >/dev/null || fail "supervisord is not installed"
tables=$(ls -A /etc/supervisor/conf.d)
[ -z "$tables" ] || fail "/etc/supervisor/conf.d is not empty: $tables"
pass "supervisord installed, without any table"

locales=$(locale -a)
for name in en_CA.utf8 fr_CA.utf8; do
    printf '%s\n' "$locales" | grep -qx "$name" || fail "the $name locale is not generated"
done
pass "en_CA.utf8 and fr_CA.utf8 generated"

mkdir -p /var/www/html/public
echo '<?php echo PHP_VERSION;' > /var/www/html/public/index.php
apache2-foreground >/dev/null 2>&1 &
for _ in $(seq 50); do
    curl -s -o /dev/null http://127.0.0.1/ && break
    sleep 0.2
done
headers=$(curl -sS --max-time 5 -D - -o /tmp/body http://127.0.0.1/ | tr -d '\r') || fail "Apache does not answer on port 80"
version=$(php -r 'echo PHP_VERSION;')
[ "$(cat /tmp/body)" = "$version" ] || fail "/ answered $(cat /tmp/body), not $version"
server=$(printf '%s\n' "$headers" | sed -n 's/^[Ss]erver: //p')
[ "$server" = Apache ] || fail "the Server header is $server, not Apache"
status=$(curl -sS --max-time 5 http://127.0.0.1/server-status) || fail "no answer for /server-status"
case "$status" in *'Apache Server Status'*) fail "/server-status answers the mod_status page" ;; esac
pass "Apache serves PHP $version, Server: Apache, no /server-status page"

echo "check-image: PASS"
INSIDE
