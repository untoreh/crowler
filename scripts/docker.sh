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

## python dyn library path
pyprefix=/usr/lib/x86_64-linux-gnu/libpython3.10
if [ $NIM = debug ]; then
    py="${pyprefix}d.so"
else
    py="${pyprefix}.so"
fi

[ -n "$docopy" ] && scripts/copy.sh $targets
for site in $sites; do
    tag=untoreh/sites:$site

    sudo docker build --target $site $nocache \
        --build-arg NIM_ARG=$NIM \
        --build-args LIBPYTHON_PATH=$py \
        -t $tag \
        -f Dockerfile docker/

    sudo docker push $tag
done
