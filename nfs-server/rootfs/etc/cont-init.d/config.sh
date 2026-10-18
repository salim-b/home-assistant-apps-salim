#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -euo pipefail

## Mount the kernel's nfsd control filesystem at /proc/fs/nfsd (the control files exist only once it is mounted; the
## mount also autoloads the nfsd kernel module in kernel context - no modprobe needed, see the repository-root
## KNOWLEDGE.md §AppArmor).
if [ ! -e /proc/fs/nfsd/versions ]; then
  bashio::log.info "Mounting nfsd filesystem..."
  if ! mount -t nfsd nfsd /proc/fs/nfsd; then
    bashio::log.fatal "Unable to mount the nfsd filesystem: the host's kernel probably lacks NFS server support."
    bashio::log.fatal "Note: Home Assistant OS only ships the nfsd kernel module on some boards"
    bashio::log.fatal "(currently the Rockchip-based ones, e.g. ODROID-M1/M1S and Home Assistant Green)."
    bashio::exit.nok
  fi
fi

## Mount rpc_pipefs in this network namespace: the kernel creates the cld tracker's upcall pipe inside the rpc_pipefs
## instance registered for the server's netns, so one must exist here for NFSv4 client state recovery (design, fallback
## behavior, verification: nfs-server/KNOWLEDGE.md §"NFSv4 client state recovery..."). Non-fatal: without it the app
## runs degraded (no cross-restart client state recovery).
RPC_PIPEFS_DIR=/var/lib/nfs/rpc_pipefs
mkdir -p "$RPC_PIPEFS_DIR"
if ! grep -qsE " on ${RPC_PIPEFS_DIR//\//\\/} rpc_pipefs " /proc/mounts; then
  bashio::log.info "Mounting rpc_pipefs (client recovery upcall channel)..."
  if ! mount -t rpc_pipefs sunrpc "$RPC_PIPEFS_DIR"; then
    bashio::log.warning "Unable to mount rpc_pipefs: NFSv4 client state will not survive app restarts."
  fi
fi

## Persistent store of the client-recovery tracker daemon (nfsdcld's sqlite
## database lives here; the daemon creates the directory itself if missing).
mkdir -p /data/nfsdcld

## NOTE: rpc.nfsd configures the kernel's NFS version set itself at server
## start (see /etc/s6-overlay/scripts/nfsd-start and KNOWLEDGE.md in the app's
## source repository for why direct writes to /proc/fs/nfsd/* don't work).

## Generate /etc/exports from the share configuration: bind-mount every share path under the app's own pseudo file
## system root on /data (the container's overlayfs root is not NFS-exportable) and export the mirrors with distinct
## numeric fsids. Why mountd is needed at all and the pseudo-root design incl. the fsid ambiguity:
## nfs-server/KNOWLEDGE.md §"NFSv4 needs rpc.mountd...".
bashio::log.info "Configuring NFS shares..."
: >/etc/exports

## Get user configuration values
DEFAULT_UID=$(bashio::config 'default_uid')
DEFAULT_GID=$(bashio::config 'default_gid')
DEFAULT_PERMS=$(bashio::config 'default_permissions')
SHARES=$(bashio::config 'shares')
if bashio::var.is_empty "$SHARES"; then
  bashio::exit.nok "No NFS shares configured. Please add shares in the app's configuration."
fi

PSEUDO_ROOT="/data/pseudo_root"
declare -A ROOT_NETWORKS=() # unique client networks of all shares
declare -a MIRROR_PATHS=()  # for unmounting in the down script
declare -A SEEN_SHARES=()   # options already configured per (path|network)
FSID=1

## Bind-mount $1 at $2 if not already mounted (idempotent)
bind_mount() {
  if ! grep -qE " on ${2//\//\\/} " /proc/mounts; then
    mkdir -p "${2}"
    if ! mount --bind "${1}" "${2}"; then
      bashio::log.fatal "Unable to bind-mount ${1} to ${2}: could not create the share's export mirror."
      bashio::exit.nok
    fi
  fi
}

## Process each share configuration
while IFS= read -r share; do
  path=$(bashio::jq "$share" '.path')
  network=$(bashio::jq "$share" '.network')
  options=$(bashio::jq "$share" '.options')

  ## Only directories mapped into the app can be exported (ephemeral or unusable otherwise).
  if [[ "$path" != /share && "$path" != /share/* &&
    "$path" != /media && "$path" != /media/* ]]; then
    bashio::log.fatal "Share path ${path} is outside of /share/ or /media/: only directories mapped into the app can be exported."
    bashio::exit.nok
  fi
  ## Clean absolute path only: used verbatim as the client-visible export path and concatenated with the pseudo root
  ## below; empty components (leading/trailing/consecutive slashes) and the filesystem root are not usable.
  if [[ ! "$path" =~ ^/[^/]+(/[^/]+)*$ ]]; then
    bashio::log.fatal "Share path '${path}' must be an absolute path without empty components (e.g. /share/nfs)."
    bashio::exit.nok
  fi
  ## /etc/exports is whitespace-separated; NFS exports must be directories.
  if [[ "$path" =~ [[:space:]] ]] || [[ "$network" =~ [[:space:]] ]] \
    || [[ "$options" =~ [[:space:]] ]]; then
    bashio::log.fatal "Share path, network and options must not contain whitespace (got: '${path} | ${network} | ${options}')."
    bashio::exit.nok
  fi
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    bashio::log.fatal "Share path ${path} is not a directory: NFS exports must be directories."
    bashio::exit.nok
  fi

  ## One option set applies per (path, network) pair: the kernel keeps a single export cache entry and the last
  ## /etc/exports line wins silently (nfs-server/KNOWLEDGE.md §"Export-cache and fsid semantics..."). The same path
  ## with *different* networks is legitimate (per-network options).
  share_key="${path}|${network}"
  if [[ -n "${SEEN_SHARES[${share_key}]+x}" ]]; then
    if [ "${SEEN_SHARES[${share_key}]}" = "$options" ]; then
      bashio::log.fatal "Share ${path} for ${network} is configured more than once with identical settings: remove the redundant duplicate entry."
    else
      bashio::log.fatal "Share ${path} for ${network} is configured more than once with conflicting options ('${SEEN_SHARES[${share_key}]}' vs '${options}'): only one option set applies per path and network - keep a single entry (separate entries are only needed for different networks)."
    fi
    bashio::exit.nok
  fi
  SEEN_SHARES["${share_key}"]="$options"

  bashio::log.info "Exporting NFS share ${path} for ${network} with options ${options}"

  ## Create the share directory if it doesn't exist, but don't modify
  ## existing ones
  if [ ! -d "$path" ]; then
    bashio::log.info "Creating directory ${path} for NFS share"
    mkdir -p "$path"
    # Set permissions using configured defaults
    chmod "$DEFAULT_PERMS" "$path"
    chown "${DEFAULT_UID}:${DEFAULT_GID}" "$path"
    bashio::log.info "Created ${path} with UID:${DEFAULT_UID} GID:${DEFAULT_GID} Permissions:${DEFAULT_PERMS}"
  fi

  ## Mirror the share path under the pseudo file system root and export it
  ## from there
  MIRROR="${PSEUDO_ROOT}${path}"
  bind_mount "$path" "$MIRROR"
  echo "${MIRROR} ${network}(fsid=${FSID},${options})" >>/etc/exports
  MIRROR_PATHS+=("$MIRROR")
  ROOT_NETWORKS["${network}"]=1
  FSID=$((FSID + 1))
done < <(echo "$SHARES")

## Export the pseudo file system root itself: read-only walk access for all client networks (the per-share entries
## control the share contents). No crossmnt needed - NFSv4 clients switch exports at mountpoint crossings regardless
## (nfs-server/KNOWLEDGE.md §"NFSv4 needs rpc.mountd...", consequences).
for network in "${!ROOT_NETWORKS[@]}"; do
  echo "${PSEUDO_ROOT} ${network}(fsid=0,ro,no_subtree_check)" >>/etc/exports
done

bashio::log.info "Configuring NFS shares completed"
