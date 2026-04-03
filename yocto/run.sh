#!/bin/sh
DIR=$(readlink -f $(dirname "$0"))
podman run -it --rm --userns=keep-id \
    -v "$DIR":/w \
    -v $(readlink -f ~/.yocto/downloads):/w/downloads \
    -v $(readlink -f ~/.yocto/sstate-cache):/w/sstate-cache \
    yocto "$@"
