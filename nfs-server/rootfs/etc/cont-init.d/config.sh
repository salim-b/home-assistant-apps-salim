#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -euo pipefail

## Make the kernel's nfsd control filesystem available at /proc/fs/nfsd.
##
## /proc/fs/nfsd is just an (empty) mountpoint which the kernel provides in
## every procfs instance; the actual control files (e.g. `versions`, `threads`)
## only exist once the `nfsd` filesystem is mounted there. Mounting it also
## autoloads the `nfsd` kernel module on hosts that ship it. For hosts without
## module autoload, we try to load the module explicitly first (host kernel
## modules are mapped into the app read-only).
if [ ! -e /proc/fs/nfsd/versions ]; then
  if command -v modprobe >/dev/null 2>&1; then
    bashio::log.info "Loading nfsd kernel module (if available)..."
    modprobe nfsd 2>/dev/null || true
  fi
  bashio::log.info "Mounting nfsd filesystem..."
  if ! mount -t nfsd nfsd /proc/fs/nfsd; then
    bashio::log.fatal "Unable to mount the nfsd filesystem: the host's kernel probably lacks NFS server support."
    bashio::log.fatal "Note: Home Assistant OS only ships the nfsd kernel module on some boards"
    bashio::log.fatal "(currently the Rockchip-based ones, e.g. ODROID-M1/M1S and Home Assistant Green)."
    bashio::exit.nok
  fi
fi

## NOTE: rpc.nfsd configures the kernel's NFS version set itself at server
## start (see /etc/s6-overlay/scripts/nfsd-start and KNOWLEDGE.md in the app's
## source repository for why direct writes to /proc/fs/nfsd/* don't work).

## Validate each share configuration and generate /etc/exports from it.
##
## Design (see KNOWLEDGE.md for the background):
## - The kernel's nfsd resolves NFSv4 paths via export-cache upcalls, which
##   are serviced by rpc.mountd - the app therefore runs a mountd service
##   (s6-rc 'mountd'), even though v4 clients never talk to it directly.
## - mountd would auto-create the pseudo file system root from the export
##   paths at `/`, but the container's overlayfs root is not NFS-exportable.
##   Hence the app builds its own pseudo file system root on `/data` (the app's
##   persistent host (ext4) volume) with bind mounts of `/share` and `/media`, so
##   client paths stay unchanged (`/share/nfs` etc.), and exports every share
##   from its mirrored path with a distinct fsid (numeric fsids keep the
##   filehandle mapping unambiguous for the bind-mounted trees).
bashio::log.info "Configuring NFS shares..."
: >/etc/exports

## Get user configuration values
DEFAULT_UID=$(bashio::config 'default_uid')
DEFAULT_GID=$(bashio::config 'default_gid')
DEFAULT_PERMS=$(bashio::config 'default_permissions')
SHARES=$(bashio::config 'shares')
if bashio::var.is_empty "${SHARES}"; then
  bashio::exit.nok "No NFS shares configured. Please add shares in the app's configuration."
fi

PSEUDO_ROOT="/data/pseudo_root"
declare -A ROOT_NETWORKS=() # unique client networks of all shares
declare -a MIRROR_PATHS=()  # for unmounting in the down script
FSID=1

## Bind-mount $1 at $2 if not already mounted (idempotent)
bind_mount() {
  if ! grep -qE " on ${2//\//\\/} " /proc/mounts; then
    mkdir -p "${2}"
    mount --bind "${1}" "${2}"
  fi
}

## Process each share configuration
while IFS= read -r share; do
  path=$(bashio::jq "$share" '.path')
  network=$(bashio::jq "$share" '.network')
  options=$(bashio::jq "$share" '.options')

  ## Only directories mapped into the app can be exported: unmapped paths
  ## would either be created in the app's ephemeral filesystem (losing all
  ## data on restart) or are plain unusable for clients.
  if [[ "${path}" != /share && "${path}" != /share/* &&
    "${path}" != /media && "${path}" != /media/* ]]; then
    bashio::log.fatal "Share path ${path} is outside of /share/ or /media/: only directories mapped into the app can be exported."
    bashio::exit.nok
  fi
  ## Must be a clean absolute path: it is used verbatim as the client-visible
  ## export path and concatenated with the pseudo file system root below;
  ## empty path components (leading/trailing or consecutive slashes) and the
  ## filesystem root are not usable export paths.
  if [[ ! "${path}" =~ ^/[^/]+(/[^/]+)*$ ]]; then
    bashio::log.fatal "Share path '${path}' must be an absolute path without empty components (e.g. /share/nfs)."
    bashio::exit.nok
  fi
  ## /etc/exports entries are whitespace-separated; also NFS exports must
  ## be directories (files cannot be export points).
  if [[ "${path}" =~ [[:space:]] ]] || [[ "${network}" =~ [[:space:]] ]] ||
    [[ "${options}" =~ [[:space:]] ]]; then
    bashio::log.fatal "Share path, network and options must not contain whitespace (got: '${path} | ${network} | ${options}')."
    bashio::exit.nok
  fi
  if [ -e "${path}" ] && [ ! -d "${path}" ]; then
    bashio::log.fatal "Share path ${path} is not a directory: NFS exports must be directories."
    bashio::exit.nok
  fi

  bashio::log.info "Exporting NFS share ${path} for ${network} with options ${options}"

  ## Create the share directory if it doesn't exist, but don't modify
  ## existing ones
  if [ ! -d "${path}" ]; then
    bashio::log.info "Creating directory ${path} for NFS share"
    mkdir -p "${path}"
    # Set permissions using configured defaults
    chmod "${DEFAULT_PERMS}" "${path}"
    chown "${DEFAULT_UID}:${DEFAULT_GID}" "${path}"
    bashio::log.info "Created ${path} with UID:${DEFAULT_UID} GID:${DEFAULT_GID} Permissions:${DEFAULT_PERMS}"
  fi

  ## Mirror the share path under the pseudo file system root and export it
  ## from there
  MIRROR="${PSEUDO_ROOT}${path}"
  bind_mount "${path}" "${MIRROR}"
  echo "${MIRROR} ${network}(fsid=${FSID},${options})" >>/etc/exports
  MIRROR_PATHS+=("${MIRROR}")
  ROOT_NETWORKS["${network}"]=1
  FSID=$((FSID + 1))
done < <(echo "${SHARES}")

## Export the pseudo file system root itself: read-only walk access for all
## client networks (the per-share entries control access to the share
## contents). No crossmnt: that flag is about (NFSv3) traversal through
## export points to mounts beneath them - NFSv4 clients switch the export at
## mountpoint crossings regardless (nfsd_cross_mnt consults the export cache
## for any v4 client), and the pseudo entries rpc.mountd synthesizes for the
## path components carry crossmnt anyway.
for network in "${!ROOT_NETWORKS[@]}"; do
  echo "${PSEUDO_ROOT} ${network}(fsid=0,ro,no_subtree_check)" >>/etc/exports
done

bashio::log.info "Configuring NFS shares completed"
