#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -euo pipefail

## Validate the app configuration and generate the hd-idle command line
## (/etc/hd-idle.args, consumed by the s6-rc hd-idle service).
##
## The whole logic lives in the hd-idle-genargs helper so that the
## hd-idle-watch longrun can re-run it periodically: it re-resolves the
## configured drives' stable by-id paths and restarts hd-idle whenever the
## generated configuration changes (drive kernel names shift when drives
## are re-plugged into other ports etc.). See hd-idle/KNOWLEDGE.md.

bashio::log.info "Configuring hd-idle..."
exec /usr/bin/hd-idle-genargs /etc/hd-idle.args