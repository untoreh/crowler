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

[ -n "$1" ] && sites="$(echo "$1" | tr "," "\n")" || sites="dev"

## python dyn library path
pyprefix=/usr/lib/x86_64-linux-gnu/libpython3.10
if [ $NIM = debug ]; then
    py="${pyprefix}d.so"
else
    py="${pyprefix}.so"
fi

[ -n "$docopy" ] && scripts/copy.sh $sites
for target in "scraper" "server"; do
    tag=untoreh/sites:$target
    sudo docker build --target $target $nocache \
        --build-arg NIM_ARG=$NIM \
        --build-arg LIBPYTHON_PATH=$py \
        -t $tag \
        -f Dockerfile docker/

    sudo docker push $tag
done
