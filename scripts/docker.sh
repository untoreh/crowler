#!/usr/bin/env bash
set -e


[ "$1" = "-n" ] && {
    nocache="--no-cache"
    shift
}
[ -n "$1" ] && site="$1" || site=wsl

scripts/copy.sh $site
tag=untoreh/sites:$site

sudo docker build --target $site $nocache \
    -t $tag \
    -f Dockerfile docker/

sudo docker push $tag
