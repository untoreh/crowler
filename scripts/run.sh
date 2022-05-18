#!/usr/bin/env bash
set -e

if [ "$(basename $PWD)" != "wsl" ]; then
    {
        echo "not in project path"
        exit 1
    }
fi

./wsl-cli start
