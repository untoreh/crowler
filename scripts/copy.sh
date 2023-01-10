#!/usr/bin/env bash
set -e
trg=docker

if [ "$1" = "-css" ]; then
    buildCss="-b"
    shift
else
    buildCss=
fi
sites="${1},default"
sites=$(echo "${sites:-dev}" | tr "," "\n")

[ -e $trg/cli ] && rm -f $trg/cli
cp requirements{,2,.git}.txt $trg/
mkdir -p $trg/run
cp -a scripts $trg/
mkdir -p $trg/logs
mkdir -p $trg/{site,lib,data}
[ $(ls $trg/data | wc -l) = 0 ] || {
    echo data dir is a volume and should be empty
    exit 1
}
mkdir -p $trg/site/assets/logo
cp -aL src/assets/logo/* $trg/site/assets/logo/
mkdir -p $trg/src
cp -a src/{assets,css,js} $trg/src/ &>/dev/null

# misc
cp -a src/assets/empty.png $trg/site/assets/
cp -a src/assets/image.svg $trg/site/assets/

mkdir -p $trg/src/nim
cp -a src/nim/*.nim $trg/src/nim/
cp -a src/nim/vendor $trg/src/nim/

mkdir -p $trg/{src/py,lib}
cp -a src/py/*.py $trg/src/py/
ln -srf $trg/src/py $trg/lib/

for site in $sites; do
    [ "$site" = scraper ] && continue
    scripts/cssconfig.sh $buildCss $site
    for fn in dist/*{.js,.css,.png}; do
        # name=$(basename ${fn%%.*})
        # ext=${fn##*.}
        mkdir -p $trg/site/assets/${site}
        cp -a $fn $trg/site/assets/${site}/$(basename ${fn})
    done
done


libminify=src/rust/minify-html/target/release/libminify_html_c.a
mkdir -p "$trg/$(dirname $libminify)"
cp -a $libminify "${trg}/${libminify}"
cp -a lib/vendor/imageflow.dist/libimageflow.so $trg/lib
libsonic=src/rust/sonic-bindings/target/release/libsonic_channel.so
mkdir -p "$trg/$(dirname $libsonic)"
cp -a $libsonic "${trg}/${libsonic}"
ln -srf "${trg}/${libsonic}" $trg/lib

cp -a nim.cfg $trg/nim.cfg.debug
cp -a nim.cfg.release $trg/nim.cfg
cp -a site.nim.cfg $trg/src/nim/cli.nim.cfg
cp -a site.nim.cfg $trg/src/nim/cli_tasks.nim.cfg
cp -a site.nimble $trg/
