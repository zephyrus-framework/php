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
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")
[ "$entrypoint" = '["docker-php-entrypoint"]' ] || fail "Entrypoint is $entrypoint, not [\"docker-php-entrypoint\"]"
onbuild=$(docker image inspect -f '{{json .Config.OnBuild}}' "$image")
case $onbuild in null|'[]') ;; *) fail "the image carries ONBUILD triggers: $onbuild" ;; esac
volumes=$(docker image inspect -f '{{json .Config.Volumes}}' "$image")
case $volumes in null|'{}') ;; *) fail "the image declares volumes: $volumes" ;; esac
user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ -z "$user" ] || fail "User is $user: the image must leave User empty, and the check runs as root on its own"
shell=$(docker image inspect -f '{{json .Config.Shell}}' "$image")
[ "$shell" = null ] || fail "the image sets a Shell: $shell"
healthcheck=$(docker image inspect -f '{{json .Config.Healthcheck}}' "$image")
[ "$healthcheck" = null ] || fail "the image sets a Healthcheck: $healthcheck"
stopsignal=$(docker image inspect -f '{{.Config.StopSignal}}' "$image")
[ "$stopsignal" = SIGWINCH ] || fail "StopSignal is $stopsignal, not SIGWINCH"
env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
names=$(printf '%s\n' "$env" | sed 's/=.*//' | LC_ALL=C sort | tr '\n' ' ')
wanted="APACHE_CONFDIR APACHE_ENVVARS APACHE_PORT GPG_KEYS PATH PHPIZE_DEPS PHP_ASC_URL PHP_CFLAGS PHP_CPPFLAGS \
PHP_INI_DIR PHP_LDFLAGS PHP_SHA256 PHP_URL PHP_VERSION TZ "
[ "$names" = "$wanted" ] || fail "the environment variables are: $names, not: $wanted"
path=$(printf '%s\n' "$env" | sed -n 's/^PATH=//p')
[ "$path" = /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ] || fail "PATH is $path"
for pair in APACHE_CONFDIR=/etc/apache2 APACHE_ENVVARS=/etc/apache2/envvars PHP_INI_DIR=/usr/local/etc/php \
    APACHE_PORT=80; do
    name=${pair%%=*}
    value=$(printf '%s\n' "$env" | sed -n "s/^$name=//p")
    [ "$value" = "${pair#*=}" ] || fail "$name is $value, not ${pair#*=}"
done
pass "Cmd, Entrypoint, 80/tcp the one exposed port, StopSignal, Env names, APACHE_CONFDIR, APACHE_ENVVARS,"
pass "PHP_INI_DIR and APACHE_PORT as built, PATH, no ONBUILD, volume, User, Shell or Healthcheck"

docker run --rm -i --user 0 "$image" /bin/sh -s <<'INSIDE'
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
cli=$(php -r 'foreach (["error_log", "mail.log", "opcache.error_log"] as $n) {
    if (ini_get($n) !== "") echo $n, "=", ini_get($n), " ";
}
if (ini_get("sendmail_path") !== "/usr/sbin/sendmail -t -i") echo "sendmail_path=", ini_get("sendmail_path");')
[ -z "$cli" ] || fail "the CLI sets log files or a mail command: $cli"
pass "php -m is clean, every module is loaded with pcntl, gd has WebP, JPEG and FreeType,"
pass "no xdebug or ssh2, apc.enable_cli on, no error_log, mail.log, opcache.error_log or sendmail_path change in the CLI"

[ -n "${PHP_VERSION:-}" ] || fail "PHP_VERSION is not set in the image"
[ ! -L /var/www/html/public ] || fail "/var/www/html/public is a link to $(readlink /var/www/html/public)"
tree=$(ls -A /var/www/html | tr '\n' ' ')
[ "$tree" = 'public ' ] || fail "/var/www/html holds ${tree% }, not a public/ directory alone"
tree=$(ls -A /var/www/html/public)
[ -z "$tree" ] || fail "/var/www/html/public is not empty: $tree"
cat > /var/www/html/public/index.php <<'PHP'
<?php
echo 'version=', PHP_VERSION, "\n";
foreach (['display_errors', 'display_startup_errors', 'log_errors', 'zend.exception_ignore_args',
    'session.use_strict_mode', 'session.upload_progress.enabled'] as $name) {
    $value = ini_get($name);
    $flag = filter_var($value, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE);
    echo $name, '=', $flag === null ? var_export($value, true) : ($flag ? 'on' : 'off'), "\n";
}
foreach (['auto_prepend_file', 'auto_append_file', 'error_log', 'mail.log', 'opcache.error_log',
    'sendmail_path'] as $name) {
    echo $name, '=', json_encode(ini_get($name), JSON_UNESCAPED_SLASHES), "\n";
}
PHP
echo 'Header set X-Public-Htaccess read' > /var/www/html/public/.htaccess
echo 'Header set X-Root-Htaccess read' > /var/www/html/.htaccess
echo 'outside public/' > /var/www/html/private.txt

syntax=$(apache2-foreground -t 2>&1)
[ "$syntax" = 'Syntax OK' ] || fail "apache2-foreground -t: $(printf '%s' "$syntax" | tr '\n' ' ')"
loaded=$(apache2-foreground -t -c 'Define DUMP_MODULES' 2>&1) || fail "apache2-foreground, DUMP_MODULES: $loaded"
loaded=$(printf '%s\n' "$loaded" | sed -n 's/^ \([a-z0-9_]*\) (.*)$/\1/p' | sort | tr '\n' ' ')
allowed="access_compat_module alias_module auth_basic_module authn_core_module authn_file_module authz_core_module \
authz_host_module authz_user_module core_module deflate_module dir_module env_module expires_module filter_module \
headers_module http_module log_config_module logio_module mime_module mpm_prefork_module negotiation_module \
php_module reqtimeout_module rewrite_module setenvif_module so_module unixd_module version_module watchdog_module"
extra=''
missing=''
for module in $loaded; do case " $allowed " in *" $module "*) ;; *) extra="$extra $module" ;; esac; done
for module in $allowed; do case " $loaded " in *" $module "*) ;; *) missing="$missing $module" ;; esac; done
[ -z "$extra$missing" ] \
    || fail "Apache loads modules outside the allowed list:${extra:- none}; misses:${missing:- none}"
for module in ssl status autoindex; do
    [ -e "/etc/apache2/mods-available/$module.load" ] || fail "$module.load is gone from mods-available"
done
sites=$(ls -A /etc/apache2/sites-enabled)
[ "$sites" = default.conf ] || fail "sites-enabled holds $sites, not default.conf alone"
settings=$(apache2-foreground -S 2>&1)
root=$(printf '%s\n' "$settings" | sed -n 's/^Main DocumentRoot: //p')
[ "$root" = '"/var/www/html/public"' ] || fail "the main server's DocumentRoot is $root, not \"/var/www/html/public\""
for dir in /var/www/html /var/www/html/public; do
    owner=$(stat -c '%U:%G %a' "$dir")
    [ "$owner" = 'root:root 755' ] || fail "$dir is $owner, not root:root 755"
done
info='LoadModule info_module /usr/lib/apache2/modules/mod_info.so'
dumped=$(apache2-foreground -t -c "$info" -c 'Define DUMP_CONFIG' 2>&1) \
    || fail "apache2-foreground -t, DUMP_CONFIG: $dumped"
dumped=$(printf '%s\n' "$dumped" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
includes=$(apache2-foreground -t -D DUMP_INCLUDES 2>&1 | sed -n 's/^ *([^)]*) //p')
[ -n "$includes" ] || fail "apache2-foreground, DUMP_INCLUDES lists no file"
IFS=$newline
set -f
for file in $includes; do
    joined=$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$file") || fail "cannot read $file"
    refused=$(printf '%s\n' "$joined" | grep -iE 'IfFile|IfDefine|^[[:space:]]*(Un)?Define([[:space:]]|$)|</?\$\{')
    [ -z "$refused" ] || fail "$file holds what DUMP_CONFIG may not show: $(printf '%s' "$refused" | tr '\n' ';')"
done
unset IFS
set +f
conditions=$(printf '%s\n' "$dumped" | grep -iE '^<(If|ElseIf|Else)([[:space:]>]|$)')
[ -z "$conditions" ] || fail "Apache parses run-time conditions: $(printf '%s' "$conditions" | tr '\n' ';')"
active=$(printf '%s\n' "$dumped" | grep -iE '^(Server(Tokens|Signature)|TraceEnable)[[:space:]]' | sort -u)
[ "$active" = "$(printf 'ServerSignature Off\nServerTokens Prod\nTraceEnable Off')" ] \
    || fail "the Server and Trace directives are: $(printf '%s' "$active" | tr '\n' ';')"
routes='(Alias|AliasMatch|ScriptAlias|ScriptAliasMatch|Listen|DocumentRoot|Rewrite[a-z]*|<VirtualHost)([[:space:]>]|$)'
routing=$(printf '%s\n' "$dumped" | LC_ALL=C sort | grep -iE "^$routes")
wanted="<VirtualHost *:$APACHE_PORT>${newline}Alias /icons/ \"/usr/share/apache2/icons/\""
# the server and the virtual host each declare the root
wanted="$wanted${newline}DocumentRoot /var/www/html/public${newline}DocumentRoot /var/www/html/public"
wanted="$wanted${newline}Listen $APACHE_PORT"
[ "$routing" = "$wanted" ] \
    || fail "Apache parses this routing: $(printf '%s' "$routing" | tr '\n' ';')" \
        "not: $(printf '%s' "$wanted" | tr '\n' ';')"
logs=$(printf '%s\n' "$dumped" \
    | LC_ALL=C sort | grep -iE '^(ErrorLog|CustomLog|TransferLog|GlobalLog|ForensicLog|ScriptLog)[[:space:]]')
wanted="CustomLog /var/log/apache2/access.log combined"
wanted="$wanted${newline}CustomLog /var/log/apache2/other_vhosts_access.log vhost_combined"
wanted="$wanted${newline}ErrorLog /var/log/apache2/error.log${newline}ErrorLog /var/log/apache2/error.log"
[ "$logs" = "$wanted" ] \
    || fail "Apache parses these log directives: $(printf '%s' "$logs" | tr '\n' ';')" \
        "not: $(printf '%s' "$wanted" | tr '\n' ';')"
for pair in access.log=/dev/stdout other_vhosts_access.log=/dev/stdout error.log=/dev/stderr; do
    target=$(readlink "/var/log/apache2/${pair%%=*}")
    [ "$target" = "${pair#*=}" ] || fail "/var/log/apache2/${pair%%=*} is not a link to ${pair#*=}${target:+, it points to $target}"
done
formats=$(printf '%s\n' "$dumped" | LC_ALL=C sort | grep -iE '^(LogFormat|ErrorLogFormat|LogLevel)[[:space:]]')
wanted='LogFormat "%h %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" combined'
wanted="$wanted${newline}"'LogFormat "%h %l %u %t \"%r\" %>s %O" common'
wanted="$wanted${newline}"'LogFormat "%v:%p %h %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" vhost_combined'
wanted="$wanted${newline}"'LogFormat "%{Referer}i -> %U" referer'
wanted="$wanted${newline}"'LogFormat "%{User-agent}i" agent'
wanted="$wanted${newline}LogLevel warn"
[ "$formats" = "$wanted" ] \
    || fail "Apache parses these log formats and levels: $(printf '%s' "$formats" | tr '\n' ';')" \
        "not: $(printf '%s' "$wanted" | tr '\n' ';')"
vhosts=$(printf '%s\n' "$settings" | sed -n '/^VirtualHost configuration:/,/^ServerRoot:/p' | sed '1d;$d' | tr -s ' ')
[ "$vhosts" = "*:$APACHE_PORT localhost (/etc/apache2/sites-enabled/default.conf:1)" ] \
    || fail "Apache serves these virtual hosts: $(printf '%s' "$vhosts" | tr '\n' ';')"
pass "Apache: the allowed modules, ssl, status and autoindex files kept, default.conf alone, ServerTokens Prod,"
pass "ServerSignature Off, TraceEnable Off, /var/www/html and public/ root:root 755, no IfFile, IfDefine, Define or"
pass "section name built from a variable in an included file; as Apache parses it, one virtual host,"
pass "DocumentRoot public/, no Alias but /icons/, no Rewrite directive, Listen \$APACHE_PORT alone,"
pass "the log directives aimed at the image's own log files, which are the output streams, with the stock formats"
pass "and LogLevel warn"

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
apache2-foreground -C 'Listen 127.0.0.1:8081' >/tmp/apache.log 2>&1 &
for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$APACHE_PORT/" && break
    sleep 0.2
done
curl -s -o /dev/null "http://127.0.0.1:$APACHE_PORT/" \
    || fail "Apache does not answer on port $APACHE_PORT: $(cat /tmp/apache.log)"

expected="version=$PHP_VERSION
display_errors=off
display_startup_errors=off
log_errors=on
zend.exception_ignore_args=on
session.use_strict_mode=on
session.upload_progress.enabled=off
auto_prepend_file=\"\"
auto_append_file=\"\"
error_log=\"\"
mail.log=\"\"
opcache.error_log=\"\"
sendmail_path=\"/usr/sbin/sendmail -t -i\""
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
    [ "$private" = 404 ] || fail "port $port: /private.txt, outside public/, answers $private, not 404"
    trace=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -X TRACE "http://127.0.0.1:$port/" 2>&1)
    [ "$trace" = 405 ] || fail "port $port: TRACE answers $trace, not 405"
done
status=$(curl -sS --max-time 5 "http://127.0.0.1:$APACHE_PORT/server-status" 2>&1)
case "$status" in *'Apache Server Status'*) fail "/server-status answers the mod_status page" ;; esac
pass "Apache serves PHP $PHP_VERSION with display_errors, display_startup_errors off, log_errors,"
pass "zend.exception_ignore_args, session.use_strict_mode on, session.upload_progress.enabled off, no auto_prepend_file"
pass "nor auto_append_file, empty error_log, mail.log and opcache.error_log, the stock sendmail_path, no X-Powered-By,"
pass "Server: Apache, .htaccess read in public/ alone,"
pass "/private.txt answering 404, TRACE refused,"
pass "on port $APACHE_PORT and on a port no vhost claims"

tree=$(LC_ALL=C ls -A /var/www/html | tr '\n' ' ')
[ "$tree" = '.htaccess private.txt public ' ] || fail "after the probes, /var/www/html holds: $tree"
tree=$(LC_ALL=C ls -A /var/www/html/public | tr '\n' ' ')
[ "$tree" = '.htaccess index.php ' ] || fail "after the probes, /var/www/html/public holds: $tree"
icons=$(find /usr/share/apache2/icons -mindepth 1 ! -type d | LC_ALL=C sort)
packaged=$(dpkg -L apache2-data | grep '^/usr/share/apache2/icons/' | while read -r file; do
    [ -d "$file" ] && [ ! -L "$file" ] || printf '%s\n' "$file"; done | LC_ALL=C sort)
[ "$icons" = "$packaged" ] || fail "/usr/share/apache2/icons differs from apache2-data; surplus:" \
    "$(printf '%s\n' "$icons" | grep -vxF "$packaged" | tr '\n' ' ')" \
    "missing: $(printf '%s\n' "$packaged" | grep -vxF "$icons" | tr '\n' ' ')"
[ -s /var/lib/dpkg/info/apache2-data.md5sums ] || fail "the apache2-data checksum list is missing or empty"
altered=$(dpkg --verify apache2-data | grep ' /usr/share/apache2/icons/')
[ -z "$altered" ] || fail "an icon differs from its package checksum: $(printf '%s' "$altered" | tr '\n' ';')"
pass "nothing but the probe files in /var/www/html and public/ once the probes are served,"
pass "the files of /usr/share/apache2/icons are the ones apache2-data installs, with its checksums"

echo "check-image: PASS"
INSIDE
