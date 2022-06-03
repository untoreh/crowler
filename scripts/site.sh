#!/usr/bin/env bash

set -e

if [ "$1" = "-s" ]; then
    COPY_ONLY=1
else
    COPY_ONLY=0
fi

lname="site"
pdir="$lname.0"
tmpdir="/tmp/$pdir"

if [ -e $tmpdir -a $COPY_ONLY = 0 ]; then
    echo "temp directory $tmpdir already exists, terminating."
    exit
fi

if [ "$(basename $PWD)" != "wsl" ]; then
    {
        echo "not in project path"
        exit 1
    }
fi

proj=$PWD
sdir="$proj/$pdir"
if [ ! -e $sdir ]; then
    echo "persistent site directory $pdir not found"
    exit 1
fi

if [ $COPY_ONLY = 0 ]; then
    cp -a $sdir /tmp
    echo "deleting local link $PWD/$lname"
    rm -f $PWD/$lname
    echo "creating local link $PWD/$lname to $tmpdir"
    ln -s $tmpdir $lname
    echo "done"
fi

mkdir -p $tmpdir/assets
cp -a "$proj/src/assets/logo" "$tmpdir/assets/"
cp -a "$proj/dist/"*{.js,.css,.png} "$tmpdir/assets/"
