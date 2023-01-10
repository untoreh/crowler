#!/usr/bin/env bash

set -e
container="scraper"

docker exec -it $container python src/py/newsite.py "$@"
docker exec -it $container scripts/supc.ch update
killall -10 caddy # USR1
