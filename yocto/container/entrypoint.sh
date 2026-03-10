#!/bin/bash
if [ -f /w/poky/oe-init-build-env ]; then
    source /w/poky/oe-init-build-env /w/build > /dev/null
fi
exec "$@"
