#!/bin/sh
# Checks what the prod target carries, as root, and stops at the first failure: ./check-image.sh <image>
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

docker run --rm -i --user 0 --entrypoint sh "$image" -s <<'INSIDE'
set -u

fail() { echo "check-image: FAIL: $*" >&2; exit 1; }
pass() { echo "check-image: ok    $*"; }
newline='
'

tools="composer git ssh scp sftp gcc cc g++ c++ make ruby gem mailcatcher cron crontab exim4 sendmail wget"
for binary in $tools; do
    found=$(command -v "$binary") && fail "$binary is installed at $found"
done
packages=$(dpkg-query -W -f '${Package}\n' | grep -E -- '-dev(:|$)')
[ -z "$packages" ] || fail "development packages are installed: $packages"
pass "none of $tools, and no -dev package"

setid=$(find / -xdev -perm /6000 -type f 2>&1) || fail "find: $setid"
[ -z "$setid" ] || fail "setuid or setgid files: $setid"
capable=$(python3 -I - <<'PY' 2>&1
import os
for top, dirs, files in os.walk("/"):
    dirs[:] = [d for d in dirs if not os.path.ismount(os.path.join(top, d))]
    for name in dirs + files:
        path = os.path.join(top, name)
        try:
            os.getxattr(path, "security.capability", follow_symlinks=False)
            print(path)
        except OSError:
            pass
PY
) || fail "python3: $capable"
[ -z "$capable" ] || fail "files with a file capability: $capable"
pass "no setuid or setgid file, no file capability"

keys=$(grep -rlI -D skip -e 'PRIVATE KEY-----' /etc /root /usr/local /var 2>&1)
case $? in
    0) fail "a private key is in the image: $keys" ;;
    1) pass "no private key in /etc, /root, /usr/local or /var" ;;
    *) fail "grep: $keys" ;;
esac

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
compiled=$(find /usr/local/lib/php -name xdebug.so -o -name ssh2.so 2>&1) || fail "find: $compiled"
[ -z "$compiled" ] || fail "an xdebug or ssh2 extension is on disk: $compiled"
named=$(grep -rli xdebug "$PHP_INI_DIR")
[ -z "$named" ] || fail "a file of $PHP_INI_DIR names xdebug: $named"
php -r 'exit(ini_get("apc.enable_cli") ? 0 : 1);' || fail "apc.enable_cli is off"
pass "php -m is clean, every module is loaded with pcntl, gd has WebP, JPEG and FreeType, no xdebug or ssh2, apc.enable_cli on"

syntax=$(apache2ctl -t 2>&1)
[ "$syntax" = 'Syntax OK' ] || fail "apache2ctl -t: $(printf '%s' "$syntax" | tr '\n' ' ')"
loaded=$(apache2ctl -M 2>&1) || fail "apache2ctl -M: $loaded"
loaded=$(printf '%s\n' "$loaded" | sed -n 's/^ \([a-z0-9_]*\) (.*)$/\1/p' | sort | tr '\n' ' ')
allowed="access_compat_module alias_module auth_basic_module authn_core_module authn_file_module authz_core_module \
authz_host_module authz_user_module core_module deflate_module dir_module env_module expires_module filter_module \
headers_module http_module log_config_module logio_module mime_module mpm_prefork_module negotiation_module \
php_module reqtimeout_module rewrite_module setenvif_module so_module unixd_module version_module watchdog_module"
extra=''
missing=''
for module in $loaded; do case " $allowed " in *" $module "*) ;; *) extra="$extra $module" ;; esac; done
for module in $allowed; do case " $loaded " in *" $module "*) ;; *) missing="$missing $module" ;; esac; done
[ -z "$extra$missing" ] || fail "Apache loads modules outside the allowed list:${extra:- none}; misses:${missing:- none}"
for module in ssl status autoindex; do
    [ -e "/etc/apache2/mods-available/$module.load" ] || fail "$module.load is gone from mods-available"
done
sites=$(ls -A /etc/apache2/sites-enabled)
[ "$sites" = default.conf ] || fail "sites-enabled holds $sites, not default.conf alone"
active=$(grep -hiE '^[[:space:]]*(Server(Tokens|Signature)|TraceEnable)[[:space:]]' /etc/apache2/apache2.conf \
    /etc/apache2/conf-enabled/*.conf /etc/apache2/sites-enabled/*.conf | sed 's#^[[:space:]]*##; s#[[:space:]]*$##' | sort -u)
[ "$active" = "$(printf 'ServerSignature Off\nServerTokens Prod\nTraceEnable Off')" ] || fail "the Server and Trace directives are: $(printf '%s' "$active" | tr '\n' ';')"
settings=$(apache2ctl -S 2>&1)
root=$(printf '%s\n' "$settings" | sed -n 's/^Main DocumentRoot: //p')
[ "$root" = '"/var/www/html/public"' ] || fail "the main server's DocumentRoot is $root, not \"/var/www/html/public\""
for dir in /var/www/html /var/www/html/public; do
    owner=$(stat -c '%U:%G %a' "$dir")
    [ "$owner" = 'root:root 755' ] || fail "$dir is $owner, not root:root 755"
done
included=$(apache2ctl -t -D DUMP_INCLUDES 2>&1 | sed -n 's/^ *([0-9*]*) //p')
routing=$(python3 -I - "$loaded" $included <<'PY' 2>&1
import re
import sys

loaded = set(sys.argv[1].split())
directive = re.compile(r"(Alias|AliasMatch|ScriptAlias|ScriptAliasMatch|Listen)\s", re.I)
opener = re.compile(r"<(IfModule|IfDefine|IfVersion|IfFile|IfSection)\s+(.*?)\s*>", re.I)
closer = re.compile(r"</If(Module|Define|Version|File|Section)>", re.I)


def holds(kind, argument):
    wanted = not argument.startswith("!")
    argument = argument.lstrip("!")
    if kind.lower() == "ifmodule":
        match = re.fullmatch(r"mod_(\w+)\.c", argument)
        return ((match.group(1) + "_module" if match else argument) in loaded) == wanted
    if kind.lower() == "ifdefine":
        return not wanted
    return True


found = []
for path in sys.argv[2:]:
    open_blocks = []
    for line in open(path, errors="replace"):
        line = line.strip()
        block = opener.fullmatch(line)
        if block:
            open_blocks.append(holds(*block.groups()))
        elif closer.fullmatch(line):
            open_blocks and open_blocks.pop()
        elif all(open_blocks) and directive.match(line):
            found.append(line)
print("\n".join(sorted(found)))
PY
) || fail "python3: $routing"
[ "$routing" = "$(printf 'Alias /icons/ "/usr/share/apache2/icons/"\nListen ${APACHE_PORT}')" ] \
    || fail "the Alias and Listen directives are: $(printf '%s' "$routing" | tr '\n' ';')"
pass "Apache: only the allowed modules, ssl, status and autoindex files kept, default.conf alone, ServerTokens Prod, ServerSignature Off, TraceEnable Off, main DocumentRoot public/, /var/www/html and public/ root:root 755, no Alias or Listen but /icons/ and \$APACHE_PORT"

command -v supervisord >/dev/null || fail "supervisord is not installed"
tables=$(ls -A /etc/supervisor/conf.d)
[ -z "$tables" ] || fail "/etc/supervisor/conf.d is not empty: $tables"
pass "supervisord installed, without any table"

locales=$(locale -a)
for name in en_CA.utf8 fr_CA.utf8; do
    printf '%s\n' "$locales" | grep -qx "$name" || fail "the $name locale is not generated"
done
pass "en_CA.utf8 and fr_CA.utf8 generated"

# Port 8081 is claimed by no <VirtualHost>, so the main server answers it.
[ -n "${PHP_VERSION:-}" ] || fail "PHP_VERSION is not set in the image"
mkdir -p /var/www/html/public
cat > /var/www/html/public/index.php <<'PHP'
<?php
echo 'version=', PHP_VERSION, "\n";
foreach (['display_errors', 'display_startup_errors', 'log_errors', 'zend.exception_ignore_args',
    'session.use_strict_mode', 'session.upload_progress.enabled'] as $name) {
    $value = ini_get($name);
    $flag = filter_var($value, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE);
    echo $name, '=', $flag === null ? var_export($value, true) : ($flag ? 'on' : 'off'), "\n";
}
PHP
echo 'Header set X-Public-Htaccess read' > /var/www/html/public/.htaccess
echo 'Header set X-Root-Htaccess read' > /var/www/html/.htaccess
echo 'outside public/' > /var/www/html/private.txt
apache2-foreground -C 'Listen 127.0.0.1:8081' >/tmp/apache.log 2>&1 &
for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$APACHE_PORT/" && break
    sleep 0.2
done
curl -s -o /dev/null "http://127.0.0.1:$APACHE_PORT/" || fail "Apache does not answer on port $APACHE_PORT: $(cat /tmp/apache.log)"

expected="version=$PHP_VERSION
display_errors=off
display_startup_errors=off
log_errors=on
zend.exception_ignore_args=on
session.use_strict_mode=on
session.upload_progress.enabled=off"
for port in "$APACHE_PORT" 8081; do
    body=$(curl -sS --max-time 5 -D /tmp/headers "http://127.0.0.1:$port/" 2>&1)
    IFS=$newline
    for line in $expected; do
        served=$(printf '%s\n' "$body" | awk -F= -v name="${line%%=*}" '$1 == name')
        [ "$served" = "$line" ] || fail "port $port: Apache serves ${served:-no ${line%%=*}}, not $line"
    done
    unset IFS
    headers=$(tr -d '\r' < /tmp/headers)
    server=$(printf '%s\n' "$headers" | sed -n 's/^[Ss]erver: //p')
    [ "$server" = Apache ] || fail "port $port: the Server header is $server, not Apache"
    powered=$(printf '%s\n' "$headers" | grep -i '^X-Powered-By:') && fail "port $port: Apache sends $powered"
    printf '%s\n' "$headers" | grep -qi '^X-Public-Htaccess: read$' || fail "port $port: public/.htaccess is not read"
    printf '%s\n' "$headers" | grep -qi '^X-Root-Htaccess:' && fail "port $port: /var/www/html/.htaccess is read"
    private=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/private.txt" 2>&1)
    [ "$private" = 404 ] || fail "port $port: a file outside public/ answers $private, not 404"
    trace=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -X TRACE "http://127.0.0.1:$port/" 2>&1)
    [ "$trace" = 405 ] || fail "port $port: TRACE answers $trace, not 405"
done
status=$(curl -sS --max-time 5 "http://127.0.0.1:$APACHE_PORT/server-status" 2>&1)
case "$status" in *'Apache Server Status'*) fail "/server-status answers the mod_status page" ;; esac
pass "Apache serves PHP $PHP_VERSION with display_errors, display_startup_errors off, log_errors, zend.exception_ignore_args, session.use_strict_mode on, session.upload_progress.enabled off, no X-Powered-By, Server: Apache, .htaccess read in public/ alone, nothing outside public/, TRACE refused, on port $APACHE_PORT and on a port no vhost claims"

echo "check-image: PASS"
INSIDE
