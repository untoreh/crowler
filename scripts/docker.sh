#!/usr/bin/env bash
set -e

scripts/copy.sh

[ "$1" = "-n" ] && nocache="--no-cache"

sudo docker build --target wsl $nocache \
    -t untoreh/sites:wsl \
    --build-arg=WEBSITE_DOMAIN=wsl \
    -f Dockerfile docker/
