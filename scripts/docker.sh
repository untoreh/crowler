#!/usr/bin/env bash
set -e

scripts/copy.sh

[ "$1" = "-n" ] && {
    nocache="--no-cache"
    shift
}
[ -n "$1" ] && site="$1" || site=wsl

sudo docker build --target $site $nocache \
    -t untoreh/sites:$site \
    -f Dockerfile docker/
