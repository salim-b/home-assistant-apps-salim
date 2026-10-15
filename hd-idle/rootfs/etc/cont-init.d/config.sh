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
if /usr/bin/hd-idle-genargs /etc/hd-idle.args; then
  ## Drive-PM treatment at boot (volatile drive settings; re-applied by the
  ## watcher on drive (re)appearance). Default on (absent key = enabled:
  ## installed options are user data and are NOT refreshed on app update -
  ## a pre-existing options.json without the key must not silently disable
  ## the feature).
  if [ "$(bashio::config 'disable_drive_pm' true)" = "true" ]; then
    /usr/bin/hd-idle-pmfix /etc/hd-idle.drives
  fi
  exit 0
fi
exit 1
