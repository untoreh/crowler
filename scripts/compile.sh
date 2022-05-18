#!/usr/bin/env bash
set -e

nim c  -d:${NIM:-debug} \
    --passL:"-flto" \
    --passL:"./lib/libminify_html_c.a" \
    -o:wsl-cli \
    $@ \
    "src/nim/cli.nim"
