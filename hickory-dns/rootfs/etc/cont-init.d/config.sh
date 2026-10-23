#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -euo pipefail

## Generate the hickory-dns configuration (/data/named.toml + static zone files + service args) and validate it
## with the real binary (--validate parses the config AND loads every zone file) before the daemon starts.
## Generator: /usr/bin/hickory-dns-genconfig (hickory-dns/KNOWLEDGE.md §"Generated named.toml").

bashio::log.info "Configuring hickory-dns..."
exec /usr/bin/hickory-dns-genconfig
