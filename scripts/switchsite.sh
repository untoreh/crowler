#!/usr/bin/env bash

set -e
[ $PWD != "${PROJECT_DIR%\/}" ] && { echo "not in project dir."; exit 1; }
[ -z "$1" ] && { echo no site name provided; exit 1; }
site_name="$1"

scripts/cssconfig.sh $site_name

logobase=src/assets/logo
logodir="${logobase}_${site_name}"
[ ! -e $logodir ] && { echo could not find logo directory "$logodir"; exit 1; }
rm -f $logobase
ln -sr $logodir $logobase

npm run build
# this should already be ran by npm
# scripts/site.sh
