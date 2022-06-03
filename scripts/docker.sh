#!/usr/bin/env bash
set -e

scripts/copy.sh

sudo docker build --target wsl \
    -t untoreh/sites:wsl \
    --build-arg=WEBSITE_DOMAIN=wsl \
    -f Dockerfile docker/
