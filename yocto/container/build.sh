#!/bin/sh
DIR=$(dirname "$0")
podman build --build-arg USER_ID=$(id -u) --build-arg GROUP_ID=$(id -g) -t yocto "$DIR"
