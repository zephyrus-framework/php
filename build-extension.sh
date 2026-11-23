#!/bin/sh
# Builds and installs a PHP extension from the archive of one GitHub commit: build-extension.sh <owner/repo> <commit>
set -eu

[ "$#" -eq 2 ] || { echo "usage: $0 <owner/repo> <commit>" >&2; exit 2; }
repository=$1
commit=$2

printf '%s\n' "$commit" | grep -qxE '[0-9a-f]{40}' || { echo "$repository: '$commit' is not a full commit SHA" >&2; exit 1; }

source=$(mktemp -d)
curl -fsSL -o "$source.tar.gz" "https://github.com/$repository/archive/$commit.tar.gz"
tar -xzf "$source.tar.gz" -C "$source" --strip-components=1
cd "$source"
phpize
# The hardening flags the official image builds its own extensions with.
./configure CFLAGS="$PHP_CFLAGS" CPPFLAGS="$PHP_CPPFLAGS" LDFLAGS="$PHP_LDFLAGS"
make -j"$(nproc)"
make install
cd /
rm -rf "$source" "$source.tar.gz"
