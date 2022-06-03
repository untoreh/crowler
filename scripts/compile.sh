#!/usr/bin/env bash
set -e

export WEBSITE_DOMAIN=wsl
export PATH=~/.nimble/bin/:$PATH
file=${1:-src/nim/cli.nim}
nim c  -d:${NIM:-debug} \
    --passL:"-flto" \
    --passL:"./lib/libminify_html_c.a" \
    -o:wsl-cli \
    $@ \
    $filestartup
