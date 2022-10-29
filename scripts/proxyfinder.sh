#!/usr/bin/env sh

proxies_dir="data/proxies"

[ -e .venv ] && . .venv/bin/activate
[ -e $proxies_dir ] ||  { echo "proxies dir not found"; exit 1; }

which proxybroker &>/dev/null || { echo "proxybroker not found"; exit 1; }
cd $proxies_dir || { echo "can't cd into proxies dir"; exit 1; }

timeout 300 proxybroker find \
    -o pbproxies.json \
    -f json \
    --types SOCKS5 SOCKS4 HTTP CONNECT:80 CONNECT:25 \
    -l 250 \
    --lvl High Anonymous
