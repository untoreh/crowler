#!/usr/bin/env bash
set -e

[ "$1" = "-n" ] && {
    nocache="--no-cache"
    shift
}

[ "$1" = "-c" ] && {
    nocopy=1
    shift
}

targets=${1:-wsl}
[ -n "$1" ] && sites="$(echo "$targets" | tr "," "\n")" || sites=wsl

[ -z "$nocopy" ] && scripts/copy.sh $targets
for site in $sites; do
    tag=untoreh/sites:$site

    sudo docker build --target $site $nocache \
        -t $tag \
        -f Dockerfile docker/

    sudo docker push $tag
done
