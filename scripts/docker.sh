#!/usr/bin/env bash
set -e

if [ "$1" = "-d" ]; then
    NIM=debug
    shift
else
    NIM=release
fi

[ "$1" = "-n" ] && {
    nocache="--no-cache"
    shift
}

[ "$1" = "-c" ] && {
    docopy=1
    shift
}

targets=${1:-wsl}
[ -n "$1" ] && sites="$(echo "$targets" | tr "," "\n")" || sites=wsl

[ -n "$docopy" ] && scripts/copy.sh $targets
for site in $sites; do
    tag=untoreh/sites:$site

    sudo docker build --target $site $nocache \
        --build-arg NIM_ARG=$NIM \
        -t $tag \
        -f Dockerfile docker/

    sudo docker push $tag
done
