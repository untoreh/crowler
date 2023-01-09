#!/usr/bin/env bash

set -e
container="scraper"

docker exec -it $container python src/py/newsite.py "$@"
killall -10 caddy # USR1
