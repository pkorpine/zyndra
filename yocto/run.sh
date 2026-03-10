#!/bin/sh
DIR=$(readlink -f $(dirname "$0"))
podman run -it --rm --userns=keep-id -v "$DIR":/w yocto "$@"
