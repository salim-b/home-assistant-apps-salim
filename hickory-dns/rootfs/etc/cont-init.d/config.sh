#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -euo pipefail

## Generate and validate the hickory-dns configuration with the real binary before the daemon starts
## (hickory-dns/KNOWLEDGE.md §"Generated named.toml").
exec /usr/bin/hickory-dns-genconfig
