#!/usr/bin/env bash

set -e

lname="site"
pdir="$lname.0"
tmpdir="/tmp/$pdir"

if [ -e $tmpdir ]; then
    echo "temp directory $tmpdir already exists, terminating."
    exit
fi

if [ "$(basename $PWD)" != "wsl" ]; then
    { echo "not in project path"; exit 1; }
fi

sdir="$PWD/$pdir"
if [ ! -e $sdir ]; then
    echo "persistent site directory $pdir not found"
    exit 1
fi

cp -a $sdir /tmp
echo "deleting local link $PWD/$lname"
rm -f $PWD/$lname
echo "creating local link $PWD/$lname to $tmpdir"
ln -s $tmpdir $lname
echo "done"
