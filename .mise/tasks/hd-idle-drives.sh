#!/usr/bin/env bash
#MISE description="Regenerate the drive cheat sheet (hd-idle/.drives.md): every connected drive with a labeled filesystem except the system disk(s), mapped to stable /dev/disk/by-id IDs (HAOS hosts only)"
#USAGE arg "<host>" help="SSH target of the Home Assistant OS device (bare host defaults to root), e.g. root@192.168.1.11 or just 192.168.1.11"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

host="${usage_host?}"
# Bare host (no user@) defaults to root: HAOS device access is root-based
case "$host" in *@*) ;; *) host="root@$host" ;; esac
SSH_OPTS=(-o ConnectTimeout=10)
OUT_FILE="hd-idle/.drives.md"

## The sheet carries the drives' stable by-id IDs - it must never be tracked by git (per-machine device
## inventory). The gitignore entry ships with the repo; refuse to write if it went missing.
if ! git check-ignore --quiet "$OUT_FILE"; then
  echo "ERROR: ${OUT_FILE} is not gitignored - refusing to write drive IDs into a trackable file (add it to .gitignore first)" >&2
  exit 1
fi

## Choose one link from a space-separated candidate list (stdout). Multiple candidates are not fatal for
## the sheet - warn and pick deterministically (lexicographically first). No candidates: return 1.
pick_from() { # $1 disk, $2 candidates, $3 class description
  local disk="$1" class="$3"
  local -a arr=()
  read -ra arr <<<"$2"
  [ "${#arr[@]}" -ge 1 ] || return 1
  if [ "${#arr[@]}" -gt 1 ]; then
    echo "WARNING: disk ${disk} has multiple ${class} by-id links (${arr[*]}) - using the lexicographically first" >&2
  fi
  printf '%s\n' "${arr[@]}" | sort | head -1
}

## Physical-drive identity for a disk (stdout): the ata-<MODEL>_<SERIAL> by-id link, which names the drive
## itself (model and serial as printed on it) - present for SATA disks and USB bridges with a SAT layer,
## i.e. every data drive hd-idle manages on a HAOS host. Partition links (-partN) are skipped.
pick_phys() {
  local disk="$1" name links=() ata="" out
  read -ra links <<<"${DISK_LINKS[$disk]:-}"
  for name in "${links[@]}"; do
    case "$name" in
      *-part*) continue ;;
      ata-*) ata+="$name " ;;
    esac
  done
  if out=$(pick_from "$disk" "$ata" "ata-*"); then
    printf '%s' "$out"
    return 0
  fi
  echo "ERROR: disk $disk has no ata-* by-id link (the drive's model+serial identity) - drive type not supported by the sheet" >&2
  exit 1
}

## Enclosure/bridge identity for a disk (stdout): the usb-* by-id link, or "-" for directly attached drives.
pick_usb() {
  local disk="$1" name links=() usb="" out
  read -ra links <<<"${DISK_LINKS[$disk]:-}"
  for name in "${links[@]}"; do
    case "$name" in
      *-part*) continue ;;
      usb-*) usb+="$name " ;;
    esac
  done
  if out=$(pick_from "$disk" "$usb" "usb-*"); then
    printf '%s' "$out"
    return 0
  fi
  printf '-'
}

## Discovery (same walk as the test:live hook): label -> parent disk, plus every by-id link. Kernel names are
## deliberately NOT carried into the sheet - they change across boots and re-plugs.
raw=$(ssh -n "${SSH_OPTS[@]}" "$host" '
  for l in /dev/disk/by-label/*; do
    [ -e "$l" ] || continue
    node=$(readlink -f "$l")
    part=${node##*/}
    if [ -e "/sys/class/block/$part/partition" ]; then
      disk=$(basename "$(dirname "$(readlink -f "/sys/class/block/$part")")")
    else
      disk=$part
    fi
    printf "label|%s|%s\n" "${l##*/}" "$disk"
  done
  for l in /dev/disk/by-id/*; do
    [ -L "$l" ] || continue
    printf "byid|%s|%s\n" "${l##*/}" "$(basename "$(readlink "$l")")"
  done
') || {
  echo "ERROR: drive discovery on '$host' failed" >&2
  exit 1
}

## DISK_LABELS: newline-joined labels per disk (a label may contain spaces); DISK_LINKS: by-id link names.
declare -A DISK_LABELS=() DISK_LINKS=()
while IFS='|' read -r kind a b; do
  [ "$kind" != "" ] || continue
  case "$kind" in
    label) DISK_LABELS[$b]+="$a"$'\n' ;;
    byid) DISK_LINKS[$b]+="$a " ;;
    *)
      echo "ERROR: unexpected discovery line: $kind|$a|$b" >&2
      exit 1
      ;;
  esac
done <<<"$raw"

if [ "${#DISK_LABELS[@]}" -eq 0 ]; then
  echo "ERROR: no labeled filesystems found on $host" >&2
  exit 1
fi

## System-disk exclusion: any disk hosting a hassos-* labeled partition is the disk Home Assistant runs
## from (boot/system/data/overlay slots - covers eMMC systems and USB-booted systems alike).
excluded=""
rows=()
mapfile -t sorted_disks < <(printf '%s\n' "${!DISK_LABELS[@]}" | sort)
for disk in "${sorted_disks[@]}"; do
  if grep -q '^hassos-' <<<"${DISK_LABELS[$disk]}"; then
    excluded+="$disk "
    continue
  fi
  labels_cell=$(sed '/^$/d' <<<"${DISK_LABELS[$disk]}" | sort | paste -sd ',' - | sed 's/,/, /g')
  rows+=("| \`$labels_cell\` | \`$(pick_phys "$disk")\` | \`$(pick_usb "$disk")\` |")
done
if [ "$excluded" != "" ]; then
  echo "-- excluded system disk(s) hosting hassos-* partitions: ${excluded%- }" >&2
fi
if [ "${#rows[@]}" -eq 0 ]; then
  echo "ERROR: no non-system drives with labeled filesystems found on $host" >&2
  exit 1
fi

## Alphabetical by label (the first table column): sort the assembled rows - they share the table prefix,
## so sorting the row strings sorts by the label cell.
mapfile -t rows < <(printf '%s\n' "${rows[@]}" | sort)

{
  printf '# Drive cheat sheet (local, not committed)\n\n'
  printf 'All drives on %s with at least one labeled filesystem, except the system disk(s) (any disk\n' "$host"
  cat <<'EOF'
hosting `hassos-*` partitions; drives without filesystem labels are invisible to this by-label
walk). The `ata-` column identifies the physical drive (model and serial as printed on it); the
`usb-` column names the enclosure/bridge - these are the entries the hd-idle app config
references. Kernel names (`sda`, ...) and `/dev/sdX` paths change between boots and re-plugs -
deliberately omitted.

| Label(s) | Drive ID (`ata-<MODEL>_<SERIAL>`) | USB-bridge ID (`usb-*`) |
| --- | --- | --- |
EOF
  printf '%s\n' "${rows[@]}"
} >"$OUT_FILE"

## Panache owns ALL markdown formatting in this repo; its repo-wide pass skips gitignored files, so the task
## formats its output explicitly (in place - a formatter failure fails the task, per set -e).
panache format "$OUT_FILE"

echo "-- wrote ${OUT_FILE} (${#rows[@]} drive(s) on $host)"
cat "$OUT_FILE"
