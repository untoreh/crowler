#!/usr/bin/env bash
set -e

BASEDIR="$(basename $PWD)"
if [ "$BASEDIR" != "wsl" ]; then
    {
        echo "not in project path"
        exit 1
    }
fi

PROXIES_DIR="$(realpath "$(dirname $BASEDIR)/data/proxies")"
[ ! -e "$proxies_dir" ] && {
    echo proxy data directory not found; exit 1;
}

N_PROXIES=100
PROXY_FILE=pbproxies.txt

. .venv/bin/activate

exec proxybroker find -o "$PROXIES_DIR/$PROXY_FILE" \
    -f txt \
    --types HTTP SOCKS4 SOCKS5 CONNECT:80 CONNECT:25 \
    -l $N_PROXIES
