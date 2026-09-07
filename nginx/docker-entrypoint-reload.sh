#!/bin/sh
# acme.sh renews the wildcard cert in a separate container, writing straight
# into the volume this nginx mounts read-only - nginx itself has no way to
# know a renewal happened, so this reloads on a timer (well under the
# 90-day cert lifetime) instead of requiring cross-container signalling.
set -e

nginx -g 'daemon off;' &
NGINX_PID=$!
trap 'kill "$NGINX_PID"' TERM INT

while true; do
    sleep 43200
    nginx -s reload || true
done &

wait "$NGINX_PID"
