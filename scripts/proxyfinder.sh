#!/usr/bin/env sh

proxies_dir="data/proxies"

[ -e .venv ] && . .venv/bin/activate
[ -e $proxies_dir ] || {
    echo "proxies dir not found"
    exit 1
}

which proxybroker &
>/dev/null || {
    echo "proxybroker not found"
    exit 1
}
cd $proxies_dir || {
    echo "can't cd into proxies dir"
    exit 1
}

findproxies() {
    file=$1
    shift
    timeout --foreground 300 proxybroker find \
        -o $file \
        -f json \
        --types $@ \
        -l 250 \
        --lvl High Anonymous
}

findproxies httpproxies.json HTTP CONNECT:80 CONNECT:25
findproxies socks5proxies.json SOCKS5
findproxies socks4proxies.json SOCKS4
