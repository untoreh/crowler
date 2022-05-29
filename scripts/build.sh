#!/usr/bin/env bash

targets=$1

if [ -s "$targets" ]; then
    sudo docker build -f docker/Dockerfile.sonic -t untoreh/sonic docker/
    sudo docker build -f docker/Dockerfile.gost -t untoreh/gost docker/
    sudo docker build -f docker/Dockerfile -t untoreh/wsl docker/
else
    [ "sonic" =~ "$targets" ] && sudo docker build -f docker/Dockerfile.sonic -t untoreh/sonic docker/
    [ "gost" =~ "$targets" ] && sudo docker build -f docker/Dockerfile.gost -t untoreh/gost docker/
    if [ "wsl" =~ "$targets" ]; then
        scripts/copy.sh
        sudo docker build -f docker/Dockerfile -t untoreh/wsl docker/
    fi
fi
