#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -euo pipefail

## Log a failed command's captured stderr as FATAL lines, one per stderr line
## (an empty capture is logged explicitly - a silent failure is itself diagnostic).
log_captured_stderr() {
  if [ -s "$1" ]; then
    while IFS= read -r line; do
      bashio::log.fatal "    ${line}"
    done <"$1"
  else
    bashio::log.fatal "    (no error output)"
  fi
}

## Mount the kernel's nfsd control filesystem at /proc/fs/nfsd (the control files exist only once it is mounted; the
## mount also autoloads the nfsd kernel module in kernel context - no modprobe/SYS_MODULE needed).
if [ ! -e /proc/fs/nfsd/versions ]; then
  bashio::log.info "Mounting nfsd filesystem..."
  ERRFILE="$(mktemp)"
  if ! mount -t nfsd nfsd /proc/fs/nfsd 2>"$ERRFILE"; then
    bashio::log.fatal "Unable to mount the nfsd filesystem. mount's error output:"
    log_captured_stderr "$ERRFILE"
    rm -f "$ERRFILE"
    bashio::log.fatal "The host's kernel probably lacks NFS server support."
    bashio::log.fatal "Note: Home Assistant OS only ships the nfsd kernel module on some boards"
    bashio::log.fatal "(currently the Rockchip-based ones, e.g. ODROID-M1/M1S and Home Assistant Green)."
    bashio::exit.nok
  fi
  rm -f "$ERRFILE"
fi

## Mount rpc_pipefs in this network namespace: the cld tracker's upcall pipe lives in the rpc_pipefs instance
## registered for the server's netns (nfs-server/KNOWLEDGE.md §"NFSv4 client state recovery (nfsdcld + per-netns rpc_pipefs)").
## Non-fatal: without it the app runs degraded (no cross-restart client state recovery).
RPC_PIPEFS_DIR=/var/lib/nfs/rpc_pipefs
mkdir -p "$RPC_PIPEFS_DIR"
if ! grep -qsE " on ${RPC_PIPEFS_DIR//\//\\/} rpc_pipefs " /proc/mounts; then
  bashio::log.info "Mounting rpc_pipefs (client recovery upcall channel)..."
  ERRFILE="$(mktemp)"
  if ! mount -t rpc_pipefs sunrpc "$RPC_PIPEFS_DIR" 2>"$ERRFILE"; then
    bashio::log.warning "Unable to mount rpc_pipefs: NFSv4 client state will not survive app restarts. mount's error output:"
    if [ -s "$ERRFILE" ]; then
      while IFS= read -r line; do
        bashio::log.warning "    ${line}"
      done <"$ERRFILE"
    fi
  fi
  rm -f "$ERRFILE"
fi

## Persistent store of the client-recovery tracker daemon (nfsdcld's sqlite database; it creates the directory itself).
mkdir -p /data/nfsdcld

## NOTE: rpc.nfsd configures the kernel's NFS version set itself at server start (nfsd-start); direct writes to
## /proc/fs/nfsd/* fail (nfs-server/KNOWLEDGE.md §"nfsd control files reject `writev(2)`").

## Generate /etc/exports and set up the share mirrors under the app's own pseudo file system root on /data (the
## container's overlayfs root is not NFS-exportable): nfs-server/KNOWLEDGE.md §"mountd and the pseudo file system root".
bashio::log.info "Configuring NFS shares..."
if ! /usr/bin/nfsd-apply --boot; then
  bashio::exit.nok "Applying the NFS share configuration failed - see the log messages above."
fi
bashio::log.info "Configuring NFS shares completed"
