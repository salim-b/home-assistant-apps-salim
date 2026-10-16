#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote commands intentionally embed client-side values
#MISE hide=true
#MISE description="⚠️ internal helper script"
# App-specific live-test hook for hd-idle, sourced by the generic
# .mise/tasks/test/live.sh harness (same split as the lab hooks). HAOS
# ships no docker CLI, so container-internal probes (and the lab's forced
# `hd-idle -t` single-shot spindown) are not reproducible from here - the
# daemon's own log events are the strictly stronger end-to-end assertion
# anyway: a logged spindown proves the whole chain (device cgroup access
# granted by the supervisor, the /dev node open inside the container, the
# SG_IO ioctl under the device-enforced AppArmor profile, and the command
# execution).
#
# Hook-local contract:
# - LIVE_HDIDLE_LABEL_GLOB (env, optional, used by live_prepare under
#   --test-options): glob matched against the filesystem labels in the
#   device's /dev/disk/by-label. live_prepare() generates the test options
#   for every disk whose labeled partitions ALL match the glob - a disk
#   hosting any other labeled partition (e.g. a data disk that must never
#   be touched) is excluded explicitly. Non-sd* disks are skipped (hd-idle
#   only monitors sd*), and the supervisor's device validation is the
#   final layer refusing system-used devices. Each included disk is mapped
#   to its preferred /dev/disk/by-id path (usb-*, then ata-*, then wwn-*,
#   then anything else) and configured with a 30 s idle (as
#   in the lab fixture) so the daemon exercises its natural spindown path
#   within the check window. The FIRST discovered drive additionally carries
#   an explicit per-drive drive-PM override (disable_drive_pm=no) so the
#   override is exercised end to end - hd-idle-pmfix must skip exactly that
#   drive (asserted in live_runtime_check). Without the variable, the repo's test options
#   file (a safe no-op: no drives) is applied unchanged. Note that
#   a match-everything glob (e.g. '*') includes every labeled disk -
#   choose the glob deliberately.
# - LIVE_HDIDLE_DISKS_JSON (set by live_prepare): JSON object mapping the
#   disks' kernel names to {label, device}; drives the per-drive assertions
#   in live_runtime_check().
#
# The label walk only sees labeled filesystems, so the glob is a test
# TARGET selector, not a safety boundary by itself (a disk whose partitions
# are all unlabeled is invisible to it). Never run with a loose glob on a
# device whose important data lives on unlabeled partitions.

# shellcheck disable=SC2034  # LIVE_* are the harness contract variables

live_prepare() {
  [ -n "${LIVE_HDIDLE_LABEL_GLOB:-}" ] || return 0
  local glob="$LIVE_HDIDLE_LABEL_GLOB" raw kind name disk rank lb byid
  local -A disk_labels=() disk_byid=() byid_rank=()
  local included=() included_sorted=() labels=() ok
  local disks_json="[]" disks_map="{}" tmpfile pm_override_disk

  echo "-- discovering drives on the device (label glob: $glob)"
  ## Partition -> parent disk via sysfs; by-id links -> kernel names.
  raw=$(ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" '
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
      case "${l##*/}" in *-part*) continue ;; esac
      printf "byid|%s|%s\n" "${l##*/}" "$(basename "$(readlink "$l")")"
    done
  ') || { echo "ERROR: drive discovery on the device failed" >&2; return 1; }

  while IFS='|' read -r kind name disk; do
    [ -n "$kind" ] || continue
    case "$kind" in
      label) disk_labels[$disk]+="${name} " ;;
      byid)
        ## Preference: usb-* (the semantically clearest entry for USB
        ## drives), then ata-*, then wwn-*, then anything else; ties go to
        ## the lexicographically first name (stable across runs).
        case "$name" in
          usb-*) rank=0 ;;
          ata-*) rank=1 ;;
          wwn-*) rank=2 ;;
          *) rank=3 ;;
        esac
        if [ -z "${disk_byid[$disk]:-}" ] || [ "$rank" -lt "${byid_rank[$disk]}" ] ||
          [[ "$rank" -eq "${byid_rank[$disk]}" && "$name" < "${disk_byid[$disk]}" ]]; then
          disk_byid[$disk]=$name
          byid_rank[$disk]=$rank
        fi
        ;;
    esac
  done <<<"$raw"

  for disk in "${!disk_labels[@]}"; do
    case "$disk" in
      sd*) ;;
      *)
        echo "   (excluding $disk: not an sd* disk - hd-idle only monitors sd*)"
        continue
        ;;
    esac
    ok=1
    read -ra labels <<<"${disk_labels[$disk]}"
    for lb in "${labels[@]}"; do
      # shellcheck disable=SC2254  # the pattern is intentionally the unquoted glob
      case "$lb" in
        $glob) ;;
        *)
          echo "   (excluding $disk: hosts the non-matching label '$lb')"
          ok=0
          ;;
      esac
    done
    if [ "$ok" = 1 ]; then included+=("$disk"); fi
  done

  if [ "${#included[@]}" -eq 0 ]; then
    echo "ERROR: no disks match label glob '$glob'" >&2
    return 1
  fi

  mapfile -t included_sorted < <(printf '%s\n' "${included[@]}" | sort)
  for disk in "${included_sorted[@]}"; do
    byid=${disk_byid[$disk]:-}
    if [ -z "$byid" ]; then
      echo "ERROR: no /dev/disk/by-id link for $disk - it cannot be configured via the device option" >&2
      return 1
    fi
    disks_json=$(jq -c --arg dev "/dev/disk/by-id/$byid" \
      '. + [{device: $dev, idle: 30, command_type: "scsi", power_condition: 0}]' <<<"$disks_json")
    disks_map=$(jq -c --arg d "$disk" --arg l "${disk_labels[$disk]%% *}" \
      --arg dev "/dev/disk/by-id/$byid" \
      '. + {($d): {label: $l, device: $dev}}' <<<"$disks_map")
  done

  ## Per-drive drive-PM override: the FIRST discovered drive carries an
  ## explicit disable_drive_pm=no so the override is exercised end to end on
  ## the device (hd-idle-pmfix must skip exactly that drive - asserted in
  ## live_runtime_check; the drives file itself is not reachable over SSH,
  ## HAOS ships no docker CLI). keys[0] == the first inserted (sorted) drive.
  pm_override_disk=$(jq -r 'keys[0]' <<<"$disks_map")
  disks_json=$(jq -c '.[0].disable_drive_pm = "no"' <<<"$disks_json")
  disks_map=$(jq -c --arg d "$pm_override_disk" '.[$d].pm_override = true' <<<"$disks_map")

  tmpfile=$(mktemp "${TMPDIR:-/tmp}/hd-idle-live-options.XXXXXX")
  jq -n --argjson disks "$disks_json" '{disks: $disks}' >"$tmpfile"
  echo "-- generated test options (30s idle, scsi):"
  jq -r 'to_entries[] | "   \(.value.device) (\(.key), label \(.value.label)\(if .value.pm_override == true then ", drive-PM override: no" else "" end))"' <<<"$disks_map"

  ## Hand the generated file to the harness's option-application and
  ## restore steps (it must outlive the run: restore_options() re-reads it
  ## from the EXIT trap for its backup sanity check).
  LIVE_TEST_OPTIONS_FILE="$tmpfile"
  export LIVE_TEST_OPTIONS_FILE
  LIVE_HDIDLE_DISKS_JSON="$disks_map"
  export LIVE_HDIDLE_DISKS_JSON
}

live_runtime_check() {
  local disks_json="${LIVE_HDIDLE_DISKS_JSON:-}" logs tail_log disk label device
  local -A spun=() labels_by_disk=()
  local -r poll=15 hard_window=90 event_window=300
  local hard_pending=1 hard_deadline=$((SECONDS + hard_window))
  local deadline=$((SECONDS + event_window))
  local cmdline declared_managed declared_excluded expected drive_count spin_events=0
  local argv=() managed_arr=() expected_arr=() i

  echo "-- hd-idle live checks (event-based; spindown window ${event_window}s)"

  ## Only the CURRENT boot's log matters: `ha apps logs` accumulates across
  ## app restarts, and this run restarts the app after applying the test
  ## options (a previous boot's "No drives configured" lines would defeat
  ## the assertions). Cut at the last "Configuring hd-idle..." line
  ## (config.sh logs it at every boot).
  while :; do
    logs=$(ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" \
      "ha apps logs $LIVE_LOCAL_SLUG" 2>/dev/null) || logs=""
    tail_log=$(awk '/Configuring hd-idle/{buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' <<<"$logs")

    if [ "$hard_pending" = 1 ]; then
      if ! grep -q "symlinkPolicy=" <<<"$tail_log"; then
        : # daemon config dump not there yet - keep waiting
      elif ! grep -q "hd-idle configuration completed" <<<"$tail_log"; then
        echo "   FAIL: the hd-idle configuration did not complete (invalid configuration?); app log tail:" >&2
        tail -15 <<<"$tail_log" | sed 's/^/         /' >&2
        return 1
      else
        ## The generated command line must manage EXACTLY the discovered
        ## drives (by kernel name) - anything else would mean the wrong
        ## disks get spun down. -a entries with idle 0 are the system-disk
        ## exclusions (defense in depth); every other -a entry must be one
        ## of the discovered drives.
        cmdline=$(grep -m1 "hd-idle command line:" <<<"$tail_log" | sed 's/^.*hd-idle command line: //')
        if [ -z "$cmdline" ]; then
          echo "   FAIL: no hd-idle command line in the app log" >&2
          return 1
        fi
        declared_managed=""
        declared_excluded=""
        read -ra argv <<<"$cmdline"
        for i in "${!argv[@]}"; do
          [ "${argv[$i]}" = "-a" ] || continue
          if [ "${argv[$((i + 2))]:-}" = "-i" ] && [ "${argv[$((i + 3))]:-}" = "0" ]; then
            declared_excluded+="${argv[$((i + 1))]} "
          else
            declared_managed+="${argv[$((i + 1))]} "
          fi
        done
        read -ra managed_arr <<<"$declared_managed"
        expected=""
        if [ -n "$disks_json" ]; then
          while IFS= read -r disk; do
            expected+="$disk "
          done < <(jq -r 'keys[]' <<<"$disks_json")
        fi
        read -ra expected_arr <<<"$expected"
        managed_sorted=$(printf '%s\n' "${managed_arr[@]}" | sort)
        expected_sorted=$(printf '%s\n' "${expected_arr[@]}" | sort)
        if [ "$managed_sorted" != "$expected_sorted" ]; then
          echo "   FAIL: hd-idle manages unexpected disks (managed: ${managed_arr[*]:-none};" >&2
          echo "         expected: ${expected_arr[*]:-none}) - refusing to continue" >&2
          return 1
        fi
        while IFS= read -r disk; do
          [ -n "$disk" ] || continue
          label=$(jq -r --arg d "$disk" '.[$d].label' <<<"$disks_json")
          device=$(jq -r --arg d "$disk" '.[$d].device' <<<"$disks_json")
          labels_by_disk[$disk]=$label
          if ! grep -qF "Drive ${device} -> ${disk}" <<<"$tail_log"; then
            echo "   FAIL: no 'Drive ${device} -> ${disk}' mapping in the app log" >&2
            echo "         (the configured by-id path did not resolve to the expected disk inside the container)" >&2
            return 1
          fi
        done < <(jq -r 'keys[]' <<<"$disks_json")
        hard_pending=0
        echo "   PASS: hd-idle daemon up, configuration completed"
        if [ -n "$disks_json" ]; then
          drive_count=$(jq length <<<"$disks_json")
          echo "   PASS: hd-idle manages exactly the ${drive_count} discovered drive(s): ${managed_arr[*]}"
          if [ -n "$declared_excluded" ]; then
            echo "   (excluded via idle-0 entries: ${declared_excluded%- })"
          fi
          ## Per-drive drive-PM override plumbing (boot log; the drives file
          ## itself is not reachable over SSH - HAOS ships no docker CLI):
          ## pmfix must have skipped EXACTLY the override drive and attempted
          ## the treatment for every other managed drive.
          pm_override_disk=$(jq -r 'to_entries[] | select(.value.pm_override == true) | .key' <<<"$disks_json")
          if [ -n "$pm_override_disk" ]; then
            if ! grep -qF "Drive ${pm_override_disk}: drive-PM treatment disabled for this drive" <<<"$tail_log"; then
              echo "   FAIL: no hd-idle-pmfix skip log for the override drive ${pm_override_disk}" >&2
              return 1
            fi
            if grep -qF "Drive ${pm_override_disk}: APM disable" <<<"$tail_log"; then
              echo "   FAIL: the override drive ${pm_override_disk} received the drive-PM treatment despite disable_drive_pm=no" >&2
              return 1
            fi
            pm_skip_count=$(grep -cF "drive-PM treatment disabled for this drive" <<<"$tail_log" || true)
            if [ "$pm_skip_count" != "1" ]; then
              echo "   FAIL: expected exactly one hd-idle-pmfix skip line (the override drive), got ${pm_skip_count}" >&2
              return 1
            fi
            for disk in "${!labels_by_disk[@]}"; do
              if [ "$disk" = "$pm_override_disk" ]; then continue; fi
              if ! grep -qF "Drive ${disk}: APM disable" <<<"$tail_log"; then
                echo "   FAIL: no hd-idle-pmfix treatment attempt logged for ${disk}" >&2
                return 1
              fi
            done
            echo "   PASS: per-drive drive-PM override (hd-idle-pmfix skipped ${pm_override_disk} only)"
          fi
        else
          if grep -q "No drives configured" <<<"$tail_log"; then
            echo "   PASS: no drives configured - hd-idle touches nothing (safe no-op options)"
          fi
        fi
      fi
    fi

    if [ -n "$disks_json" ]; then
      while IFS= read -r disk; do
        [ -n "$disk" ] || continue
        if grep -q "${disk} spindown" <<<"$tail_log"; then spun[$disk]=1; fi
      done < <(jq -r 'keys[]' <<<"$disks_json")
    fi

    ## All discovered drives have issued their spindown event - or (no-op
    ## options) the boot assertions passed and there is nothing to wait for.
    if [ "$hard_pending" = 0 ]; then
      if [ -z "$disks_json" ] || [ "${#spun[@]}" -eq "$(jq length <<<"$disks_json")" ]; then
        break
      fi
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    if [ "$hard_pending" = 1 ] && [ "$SECONDS" -ge "$hard_deadline" ]; then
      echo "   FAIL: the hd-idle boot assertions were not satisfied within ${hard_window}s; app log tail:" >&2
      tail -15 <<<"$tail_log" | sed 's/^/         /' >&2
      return 1
    fi
    sleep "$poll"
  done

  if grep -qEi "error|denied|failed" <<<"$tail_log" 2>/dev/null; then
    echo "   (note: error-ish lines in the current boot's app log:"
    grep -Ei "error|denied|failed" <<<"$tail_log" | tail -5 | sed 's/^/         /'
    echo "   )"
  fi

  if [ -n "$disks_json" ]; then
    drive_count=$(jq length <<<"$disks_json")
    echo "-- spindown events per drive (daemon-issued, natural idle path):"
    while IFS= read -r disk; do
      [ -n "$disk" ] || continue
      label=${labels_by_disk[$disk]:-?}
      if [ -n "${spun[$disk]:-}" ]; then
        echo "   PASS: $disk ($label) spundown event seen"
        spin_events=$((spin_events + 1))
      else
        echo "   WARN: $disk ($label) no spindown event within ${event_window}s (drive busy/mounted? IO keeping it awake?)"
      fi
    done < <(jq -r 'keys[]' <<<"$disks_json")
    if [ "$spin_events" -eq 0 ]; then
      echo "   FAIL: not a single configured drive reached a daemon-issued spindown within ${event_window}s" >&2
      echo "         (all drives busy? command type wrong for these bridges? device access missing?)" >&2
      return 1
    fi
    echo "   PASS: $spin_events/$drive_count configured drive(s) issued spindown events"
  fi
  return 0
}
