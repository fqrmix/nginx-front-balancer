#!/usr/bin/env sh

# Custom acme.sh dnsapi provider for HOSTKEY's PowerDNS-based DNS API
# (https://hostkey.ru/documentation/apidocs/pdns/ - the .ru account/API
# host, invapi.hostkey.ru, is a separate endpoint from hostkey.com's
# invapi.hostkey.com; a hostkey.ru token only works against .ru). HOSTKEY
# has no official acme.sh or certbot plugin, so this talks to pdns.php
# directly.
#
# Deliberately NOT a generic provider: a real dnsapi script has to walk
# up the label chain calling the registrar's "does this zone exist" API
# to figure out where the apex zone boundary is, because acme.sh only
# ever hands it the full challenge hostname. We only ever issue for one
# zone, so that's skipped in favour of stripping a fixed, configured
# suffix - see HOSTKEY_ZONE below. Point of difference from Beget's API:
# add_dns/delete_dns touch one record at a time, so unlike Beget there's
# no risk of this wiping the zone's other A/MX/etc. records.
#
# Required env var: HOSTKEY_TOKEN  (invapi.hostkey.com API token)
# Optional env var: HOSTKEY_ZONE   (defaults to fqrmix.ru)

HOSTKEY_API="https://invapi.hostkey.ru/pdns.php"

dns_hostkey_add() {
  fulldomain=$1
  txtvalue=$2
  _hostkey_init "$fulldomain" || return 1

  _info "hostkey: adding TXT $_sub_domain.$_zone"
  response=$(_post "action=add_dns&token=$HOSTKEY_TOKEN&params[zone]=$_zone&params[name]=$_sub_domain&params[type]=TXT&params[content][]=$txtvalue&params[ttl]=60" "$HOSTKEY_API")

  if _contains "$response" '"result":"OK"' || _contains "$response" '"result": "OK"'; then
    return 0
  fi
  _err "hostkey: add_dns failed: $response"
  return 1
}

dns_hostkey_rm() {
  fulldomain=$1
  txtvalue=$2
  _hostkey_init "$fulldomain" || return 1

  _info "hostkey: removing TXT $_sub_domain.$_zone"
  response=$(_post "action=delete_dns&token=$HOSTKEY_TOKEN&params[zone]=$_zone&params[name]=$_sub_domain&params[type]=TXT" "$HOSTKEY_API")

  if _contains "$response" '"result":"OK"' || _contains "$response" '"result": "OK"'; then
    return 0
  fi
  # Non-fatal: acme.sh already has its validated cert at this point:
  # cleanup failing just leaves a stale TXT record behind.
  _err "hostkey: delete_dns failed (continuing anyway): $response"
  return 0
}

_hostkey_init() {
  fulldomain=$1
  HOSTKEY_TOKEN="${HOSTKEY_TOKEN:-$(_readaccountconf_mutable HOSTKEY_TOKEN)}"
  if [ -z "$HOSTKEY_TOKEN" ]; then
    _err "HOSTKEY_TOKEN is not set"
    return 1
  fi
  _saveaccountconf_mutable HOSTKEY_TOKEN "$HOSTKEY_TOKEN"

  _zone="${HOSTKEY_ZONE:-fqrmix.ru}"
  fulldomain="${fulldomain%.}"
  case "$fulldomain" in
    "$_zone")
      _sub_domain="@"
      ;;
    *".$_zone")
      _sub_domain="${fulldomain%."$_zone"}"
      ;;
    *)
      _err "hostkey: $fulldomain is not under zone $_zone (set HOSTKEY_ZONE if that's wrong)"
      return 1
      ;;
  esac
}
