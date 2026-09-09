#!/bin/sh
# Runs inside the acme_issue container. Kept as a real file (not an inline
# `command: |` string in docker-compose.yaml) specifically so shell
# variables like $code/$? are never touched by Compose's own ${VAR}
# interpolation of the YAML file - that bit us once already: Compose
# silently replaced $code with an empty string before the shell ever saw
# it, turning `[ "$code" -eq 2 ]` into `[ "" -eq 2 ]` ("Illegal number").
set -e

mkdir -p /certs/fqrmix.ru

# acme.sh exits 2 (not 0) when the cert is already valid and renewal
# isn't due yet ("Domains not changed. Skipping.") - that's success for
# us, not a failure, so `set -e` must not treat it as one, or
# --install-cert below never runs.
acme.sh --issue --dns dns_beget \
  -d fqrmix.ru \
  -d '*.fqrmix.ru' \
  -d '*.yoomoney-services.fqrmix.ru' \
  -d '*.services.fqrmix.ru' \
  --server letsencrypt || {
    code=$?
    [ "$code" -eq 2 ] || exit "$code"
  }

acme.sh --install-cert -d fqrmix.ru \
  --key-file       /certs/fqrmix.ru/privkey.pem \
  --fullchain-file /certs/fqrmix.ru/fullchain.pem
