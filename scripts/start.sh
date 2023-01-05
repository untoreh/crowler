#!/bin/sh

tmux source /etc/tmux.d/docker.conf
# Keep gost version synced among client/nodes to avoid problems
docker run --name $CONFIG_NAME -d --restart unless-stopeed \
    -it -v /opt/gst/gst:/usr/local/bin/gost:ro \
    -v /mnt/host/data:/site/data \
    untoreh/sites:server \
    ./cli start
