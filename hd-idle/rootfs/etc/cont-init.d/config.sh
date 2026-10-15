#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -euo pipefail

## Validate the app configuration and generate the hd-idle command line (/etc/hd-idle.args, consumed by the s6-rc
## hd-idle service). The logic lives in the shared hd-idle-genargs helper so the hd-idle-watch longrun can re-run it
## (hd-idle/KNOWLEDGE.md §"Automatic drive re-resolution").

bashio::log.info "Configuring hd-idle..."
if /usr/bin/hd-idle-genargs /etc/hd-idle.args; then
  ## Drive-PM treatment at boot (re-applied by the watcher on drive (re)appearance). Default on for absent keys
  ## (options are user data - repository-root KNOWLEDGE.md §"Supervisor: option schema quirks"). Non-fatal, like the
  ## watcher's re-application: the treatment is best-effort.
  if [ "$(bashio::config 'disable_drive_pm' true)" = "true" ]; then
    /usr/bin/hd-idle-pmfix /etc/hd-idle.drives ||
      bashio::log.warning "hd-idle-pmfix failed - the drives' power management stays as is."
  fi
  exit 0
fi
exit 1
