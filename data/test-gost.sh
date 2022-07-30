#!/usr/bin/env bash

gost -L ss+quic://:9999 &
sleep 1
gost -L :8888 -F ss+quic://localhost:9999 &
sleep 1
curl --proxy socks5://localhost:8888 ipinfo.io
gost -L :8888 -F ss+quic://aes-128-cfb:128@127.0.0.1:80 &
