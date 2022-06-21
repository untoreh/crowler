#!/usr/bin/env bash

[ -z "$1" ] && { echo provide a site name as argument; exit 1; }
site="$1"

mkdir -p $site/{cache,proxies}
touch $site/blacklist.txt
