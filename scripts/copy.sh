#!/usr/bin/env bash

trg=docker
cp requirements.txt $trg/
mkdir -p $trg/run
cp -a scripts $trg/
mkdir -p $trg/logs
mkdir -p $trg/{site,lib,data}
[ $(ls $trg/data | wc -l) = 0 ] || { echo data dir is a volume and should be empty; exit 1; }
cp -a src/assets/logo $trg/site/assets
cp -a src/{assets,css,js} $trg/src/ &>/dev/null
mkdir -p $trg/src/nim
cp -a src/nim/*.nim $trg/src/nim/
cp -a src/nim/vendor $trg/src/nim/

mkdir -p $trg/{src/py,lib}
cp -a src/py/*.py $trg/src/py/
ln -srf $trg/src/py $trg/lib/

cp -a dist/*{.js,.css,.png} $trg/site/assets
cp -a dist/*{.js,.css,.png} $trg/site/assets
libminify=src/rust/target/release/libminify_html_c.a
mkdir -p "$trg/$(dirname $libminify)"
cp -a $libminify $trg/$libminify
cp -a lib/vendor/imageflow.dist/libimageflow.so $trg/lib
cp -a nim.cfg $trg/
cp -a wsl.nimble $trg/
