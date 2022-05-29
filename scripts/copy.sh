#!/usr/bin/env bash

trg=docker
cp wsl-cli $trg/
cp requirements.txt $trg/
cp -a run $trg/
cp -a scripts $trg/
cp -a logs $trg/
mkdir -p $trg/{site,lib,data}
cp -a src/assets/logo $trg/site/assets
cp -a src/{assets,css,js,nim,py,topics} $trg/src/
cp -a src/py $trg/lib/
cp -a dist/*{.js,.css,.png} $trg/site/assets
cp -a dist/*{.js,.css,.png} $trg/site/assets
cp -a src/py $trg/lib
libminify=src/rust/target/release/libminify_html_c.a
mkdir -p "$trg/$(dirname $libminify)"
cp -a $libminify $trg/$libminify
cp -a lib/vendor/imageflow.dist/libimageflow.so $trg/lib
