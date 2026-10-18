#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -euo pipefail

## Validate the app configuration and generate the hd-idle command line (/etc/hd-idle.args, consumed by the s6-rc
## hd-idle service). The logic lives in the shared hd-idle-genargs helper so the hd-idle-watch longrun can re-run it
## (hd-idle/KNOWLEDGE.md §"Automatic drive re-resolution").

bashio::log.info "Configuring hd-idle..."
if /usr/bin/hd-idle-genargs /etc/hd-idle.args; then
  ## Drive-PM treatment at boot (re-applied by the watcher on drive (re)appearance). Runs unconditionally: the
  ## drives file's pm-flag column carries the EFFECTIVE per-drive decision (global disable_drive_pm as the
  ## default, per-drive yes/no overrides), and pmfix skips every drive whose flag is 0 - a global-only bashio
  ## gate could not express per-drive overrides. Non-fatal, like the watcher's re-application: the treatment is
  ## best-effort.
  /usr/bin/hd-idle-pmfix /etc/hd-idle.drives \
    || bashio::log.warning "hd-idle-pmfix failed - the drives' power management stays as is."
  exit 0
fi
exit 1
