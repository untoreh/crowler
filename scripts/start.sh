#!/bin/sh

tmux source /etc/tmux.d/docker.conf
# Keep gost version synced among client/nodes to avoid problems
docker run --name wsl -d --restart unless-stopeed \
    -it -v /opt/gst/gst:/usr/local/bin/gost:ro \
    -v /mnt/wsl/data:/wsl/data \
    untoreh/sites:wsl \
    ./cli start
