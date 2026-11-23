#!/usr/bin/env bash
#MISE hide=true
#MISE description="⚠️ internal helper script"
# App-specific live-test hook for hd-idle, sourced by .mise/tasks/test/live.sh; hook contract:
# .agents/skills/ha-app-device-testing. HAOS ships no docker CLI, so container-internal probes
# (and the lab's forced `hd-idle -t` single-shot spindown) are not reproducible from here – the
# daemon's own log events are the strictly stronger end-to-end assertion anyway: a logged spindown
# proves the whole chain (device cgroup access, the /dev node open inside the container, the SG_IO
# ioctl under the device-enforced AppArmor profile, and the command execution).
#
# Hook-local contract:
# - LIVE_HDIDLE_LABEL_GLOB (env, optional, read by live_prepare under --test-options): a test TARGET
#   selector over filesystem labels – space-separated glob PATTERNS (bash case alternation does not work
#   through a variable); a label matches when it matches any pattern. A disk is included only if ALL its
#   labeled partitions match; disks hosting other labeled partitions are excluded explicitly; non-sd*
#   disks are skipped (hd-idle only monitors sd*); the supervisor's device validation is the final layer
#   refusing system-used devices. Each included disk maps to its preferred /dev/disk/by-id path (ata-* > usb-*
#   > wwn-*) and gets a 30 s idle so the daemon exercises its natural spindown path within the check
#   window; the FIRST discovered drive additionally opts out of the drive-PM treatment
#   (keep_drive_pm=true), exercised end to end (asserted in live_runtime_check).
# - LIVE_HDIDLE_COMMAND_TYPE (env, optional): the per-drive command type for the generated test options
#   (default scsi, as in the lab fixture; set ata on devices whose production drives use the ata path –
#   some WD bridges silently no-op scsi commands: hd-idle/KNOWLEDGE.md §"USB-bridge behaviors").
# - LIVE_HDIDLE_RENAME_DISK (env, optional, read by live_rename_check after the soak): the port-move
#   scenario. Value: a managed kernel name or the filesystem label of exactly one included drive.
#   Waits (operator-paced, up to LIVE_HDIDLE_RENAME_TIMEOUT seconds, default 1800) for the drive to be
#   unplugged and re-attached to a DIFFERENT port, then asserts the watcher's end-to-end promise
#   (hd-idle/KNOWLEDGE.md §"hd-idle-watch design"): regeneration, hd-idle service restart, the drive
#   re-resolved under its NEW kernel name, the hd-idle-pmfix decision on the changed drives-file line,
#   and a daemon-issued spindown under the new name – the supervisor's hotplug re-grant keeps the
#   device-access chain (cgroup rules + AppArmor) open without an app restart. Device-verified 2026-11-24
#   (WD USB drive moved across ports, all assertions passed). Moving the drive detaches it from every
#   consumer (NFS exports, mounts) – move a drive whose downtime is acceptable.
#   Without the variable, the repo's test options file (a safe no-op: no drives) is applied unchanged. A
#   match-everything glob includes every labeled disk – choose it deliberately.
# - LIVE_HDIDLE_DISKS_JSON (set by live_prepare): JSON object mapping the disks' kernel names to
#   {label, device}; drives the per-drive assertions in live_runtime_check().
#
# The label walk only sees labeled filesystems: the glob is a test TARGET selector, not a safety
# boundary by itself (a disk whose partitions are all unlabeled is invisible). Never run with a loose
# glob on a device whose important data lives on unlabeled partitions.

# shellcheck disable=SC2029  # remote commands intentionally embed client-side values
# shellcheck disable=SC2034  # LIVE_* are the harness contract variables

live_prepare() {
  [ "${LIVE_HDIDLE_LABEL_GLOB:-}" != "" ] || return 0
  local glob="$LIVE_HDIDLE_LABEL_GLOB" raw kind name disk rank lb byid
  local -A disk_labels=() disk_byid=() byid_rank=()
  local included=() included_sorted=() labels=() ok matched pat
  local -a glob_patterns=()
  local disks_json="[]" disks_map="{}" tmpfile pm_optout_disk

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
  ') || {
    echo "ERROR: drive discovery on the device failed" >&2
    return 1
  }

  while IFS='|' read -r kind name disk; do
    [ "$kind" != "" ] || continue
    case "$kind" in
      label) disk_labels[$disk]+="${name} " ;;
      byid)
        ## Preference: ata-* (the drive-physical link: its name derives from model + serial only and is
        ## stable across ports, hosts and boots – the production options reference ata-* paths), then
        ## usb-* (bridge/enclosure identity, carries an interface-instance suffix), wwn-*, then anything
        ## else; ties go to the lexicographically first name (stable across runs).
        case "$name" in
          ata-*) rank=0 ;;
          usb-*) rank=1 ;;
          wwn-*) rank=2 ;;
          *) rank=3 ;;
        esac
        if [ "${disk_byid[$disk]:-}" = "" ] || [ "$rank" -lt "${byid_rank[$disk]}" ] \
          || [[ "$rank" -eq "${byid_rank[$disk]}" && "$name" < "${disk_byid[$disk]}" ]]; then
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
        echo "   (excluding $disk: not an sd* disk – hd-idle only monitors sd*)"
        continue
        ;;
    esac
    ok=1
    read -ra labels <<<"${disk_labels[$disk]}"
    read -ra glob_patterns <<<"$glob"
    for lb in "${labels[@]}"; do
      matched=0
      for pat in "${glob_patterns[@]}"; do
        # shellcheck disable=SC2254  # the pattern is intentionally the unquoted glob
        case "$lb" in
          $pat)
            matched=1
            break
            ;;
        esac
      done
      if [ "$matched" != "1" ]; then
        echo "   (excluding $disk: hosts the non-matching label '$lb')"
        ok=0
      fi
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
    if [ "$byid" = "" ]; then
      echo "ERROR: no /dev/disk/by-id link for $disk – it cannot be configured via the device option" >&2
      return 1
    fi
    disks_json=$(jq -c --arg dev "/dev/disk/by-id/$byid" --arg ct "${LIVE_HDIDLE_COMMAND_TYPE:-scsi}" \
      '. + [{device: $dev, idle: 30, command_type: $ct, power_condition: 0}]' <<<"$disks_json")
    disks_map=$(jq -c --arg d "$disk" --arg l "${disk_labels[$disk]%% *}" \
      --arg dev "/dev/disk/by-id/$byid" \
      '. + {($d): {label: $l, device: $dev}}' <<<"$disks_map")
  done

  ## Per-drive keep-drive-PM opt-out: the FIRST discovered drive gets keep_drive_pm=true, exercised end
  ## to end on the device (hd-idle-pmfix must skip exactly that drive – asserted in
  ## live_runtime_check; the drives file is not reachable over SSH, HAOS ships no docker CLI).
  ## keys[0] == the first inserted (sorted) drive.
  pm_optout_disk=$(jq -r 'keys[0]' <<<"$disks_map")
  disks_json=$(jq -c '.[0].keep_drive_pm = true' <<<"$disks_json")
  disks_map=$(jq -c --arg d "$pm_optout_disk" '.[$d].pm_optout = true' <<<"$disks_map")

  tmpfile=$(mktemp "${TMPDIR:-/tmp}/hd-idle-live-options.XXXXXX")
  jq -n --argjson disks "$disks_json" '{disks: $disks}' >"$tmpfile"
  echo "-- generated test options (30s idle, ${LIVE_HDIDLE_COMMAND_TYPE:-scsi}):"
  jq -r 'to_entries[] | "   \(.value.device) (\(.key), label \(.value.label)\(if .value.pm_optout == true then ", keep drive power management: on" else "" end))"' <<<"$disks_map"

  ## Must outlive the run: restore_options() re-reads it from the EXIT trap for its backup sanity check.
  LIVE_TEST_OPTIONS_FILE="$tmpfile"
  export LIVE_TEST_OPTIONS_FILE
  LIVE_HDIDLE_DISKS_JSON="$disks_map"
  export LIVE_HDIDLE_DISKS_JSON
}

live_runtime_check() {
  local disks_json="${LIVE_HDIDLE_DISKS_JSON:-}" logs tail_log disk label device byid inv_line
  local -A spun=() labels_by_disk=()
  local -r poll=15 hard_window=90 event_window=300
  local hard_pending=1 hard_deadline=$((SECONDS + hard_window))
  local deadline=$((SECONDS + event_window))
  local cmdline declared_managed declared_excluded expected drive_count spin_events=0
  local argv=() managed_arr=() expected_arr=() i

  echo "-- hd-idle live checks (event-based; spindown window ${event_window}s)"

  ## Only the CURRENT boot's log matters: `ha apps logs` serves the host journal (root KNOWLEDGE.md
  ## §"Supervisor: app and host logs are served from systemd-journald") and accumulates across app
  ## restarts within the host boot – this run restarts the app after applying the test options (a
  ## previous boot's "No drives configured" lines would defeat the assertions). Fetch a generous
  ## window of the current host boot (the default is the last 100 entries only), then cut at the
  ## last "Configuring hd-idle..." line (config.sh logs it at every boot).
  while :; do
    logs=$(ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" \
      "ha apps logs $LIVE_LOCAL_SLUG --boot 0 --lines 400" 2>/dev/null) || logs=""
    tail_log=$(awk '/Configuring hd-idle/{buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' <<<"$logs")

    if [ "$hard_pending" = 1 ]; then
      if ! grep -q "symlinkPolicy=" <<<"$tail_log"; then
        : # daemon config dump not there yet – keep waiting
      elif ! grep -q "hd-idle configuration completed" <<<"$tail_log"; then
        echo "   FAIL: the hd-idle configuration did not complete (invalid configuration?); app log tail:" >&2
        tail -15 <<<"$tail_log" | sed 's/^/         /' >&2
        return 1
      else
        ## The generated command line must manage EXACTLY the discovered drives (by kernel name) – anything
        ## else would spin the wrong disks. -a entries with idle 0 are the system-disk exclusions
        ## (defense in depth); every other -a entry must be one of the discovered drives.
        cmdline=$(grep -m1 "hd-idle command line:" <<<"$tail_log" | sed 's/^.*hd-idle command line: //')
        if [ "$cmdline" = "" ]; then
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
        if [ "$disks_json" != "" ]; then
          while IFS= read -r disk; do
            expected+="$disk "
          done < <(jq -r 'keys[]' <<<"$disks_json")
        fi
        read -ra expected_arr <<<"$expected"
        managed_sorted=$(printf '%s\n' "${managed_arr[@]}" | sort)
        expected_sorted=$(printf '%s\n' "${expected_arr[@]}" | sort)
        if [ "$managed_sorted" != "$expected_sorted" ]; then
          echo "   FAIL: hd-idle manages unexpected disks (managed: ${managed_arr[*]:-none};" >&2
          echo "         expected: ${expected_arr[*]:-none}) – refusing to continue" >&2
          return 1
        fi
        while IFS= read -r disk; do
          [ "$disk" != "" ] || continue
          label=$(jq -r --arg d "$disk" '.[$d].label' <<<"$disks_json")
          device=$(jq -r --arg d "$disk" '.[$d].device' <<<"$disks_json")
          labels_by_disk[$disk]=$label
          ## The configured path must resolve to the host-discovered disk inside the container. The mapping
          ## line is logged only when the configured path is not the by-id link the inventory shows for the
          ## disk; otherwise the disk's inventory line carries that link itself.
          byid=${device#/dev/disk/by-id/}
          if ! grep -qF "Drive ${device} -> ${disk}" <<<"$tail_log"; then
            inv_line=$(grep -F "  ${disk}: " <<<"$tail_log" || true)
            if ! grep -qF "by-id: ${byid}" <<<"$inv_line"; then
              echo "   FAIL: no 'Drive ${device} -> ${disk}' mapping and no 'by-id: ${byid}' on the ${disk} inventory line" >&2
              echo "         (the configured by-id path did not resolve to the expected disk inside the container)" >&2
              return 1
            fi
          fi
        done < <(jq -r 'keys[]' <<<"$disks_json")
        hard_pending=0
        echo "   PASS: hd-idle daemon up, configuration completed"
        if [ "$disks_json" != "" ]; then
          drive_count=$(jq length <<<"$disks_json")
          echo "   PASS: hd-idle manages exactly the ${drive_count} discovered drive(s): ${managed_arr[*]}"
          if [ "$declared_excluded" != "" ]; then
            echo "   (excluded via idle-0 entries: ${declared_excluded%- })"
          fi
          ## Per-drive keep-drive-PM opt-out plumbing (boot log; the drives file is not reachable over SSH – HAOS
          ## ships no docker CLI): pmfix must have skipped EXACTLY the opt-out drive and attempted the
          ## treatment for every other managed drive.
          pm_optout_disk=$(jq -r 'to_entries[] | select(.value.pm_optout == true) | .key' <<<"$disks_json")
          if [ "$pm_optout_disk" != "" ]; then
            if ! grep -qF "Drive ${pm_optout_disk}: drive-PM treatment disabled for this drive" <<<"$tail_log"; then
              echo "   FAIL: no hd-idle-pmfix skip log for the opt-out drive ${pm_optout_disk}" >&2
              return 1
            fi
            if grep -qF "Drive ${pm_optout_disk}: APM disable" <<<"$tail_log"; then
              echo "   FAIL: the opt-out drive ${pm_optout_disk} received the drive-PM treatment despite keep_drive_pm=true" >&2
              return 1
            fi
            pm_skip_count=$(grep -cF "drive-PM treatment disabled for this drive" <<<"$tail_log" || true)
            if [ "$pm_skip_count" != "1" ]; then
              echo "   FAIL: expected exactly one hd-idle-pmfix skip line (the opt-out drive), got ${pm_skip_count}" >&2
              return 1
            fi
            for disk in "${!labels_by_disk[@]}"; do
              if [ "$disk" = "$pm_optout_disk" ]; then continue; fi
              if ! grep -qF "Drive ${disk}: APM disable" <<<"$tail_log"; then
                echo "   FAIL: no hd-idle-pmfix treatment attempt logged for ${disk}" >&2
                return 1
              fi
            done
            echo "   PASS: per-drive keep-drive-PM opt-out (hd-idle-pmfix skipped ${pm_optout_disk} only)"
          fi
        else
          if grep -q "No drives configured" <<<"$tail_log"; then
            echo "   PASS: no drives configured – hd-idle touches nothing (safe no-op options)"
          fi
        fi
      fi
    fi

    if [ "$disks_json" != "" ]; then
      while IFS= read -r disk; do
        [ "$disk" != "" ] || continue
        if grep -q "${disk} spindown" <<<"$tail_log"; then spun[$disk]=1; fi
      done < <(jq -r 'keys[]' <<<"$disks_json")
    fi

    ## All discovered drives have issued their spindown event – or (no-op options) the boot assertions passed.
    if [ "$hard_pending" = 0 ]; then
      if [ "$disks_json" = "" ] || [ "${#spun[@]}" -eq "$(jq length <<<"$disks_json")" ]; then
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

  if [ "$disks_json" != "" ]; then
    drive_count=$(jq length <<<"$disks_json")
    echo "-- spindown events per drive (daemon-issued, natural idle path):"
    while IFS= read -r disk; do
      [ "$disk" != "" ] || continue
      label=${labels_by_disk[$disk]:-?}
      if [ "${spun[$disk]:-}" != "" ]; then
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

  ## Port-move rename scenario (optional knob): runs after the soak while the test options are still
  ## active – it needs the drive configured and the daemon managing it. Operator-paced: the hook waits
  ## for the physical port move (live_rename_check prints the instruction and polls).
  if [ "${LIVE_HDIDLE_RENAME_DISK:-}" != "" ]; then
    live_rename_check || return 1
  fi
  return 0
}

live_rename_check() { # the port-move scenario (knob LIVE_HDIDLE_RENAME_DISK): the watcher's end-to-end promise.
  # Operator-paced: waits for the physical unplug + re-attach to a DIFFERENT port, then asserts – from the app
  # log alone (no docker CLI on the device: hook header) – the regeneration, the hd-idle service restart with
  # the drive re-resolved under its new kernel name, the hd-idle-pmfix decision on the changed drives-file
  # line, and a daemon-issued spindown under the new name (the device-access proof: the supervisor's hotplug
  # re-grant keeps the cgroup rules open for the renamed node without an app restart). The configured by-id
  # path (ata-* preferred: live_prepare) is stable across ports, so the drive keeps its configured identity;
  # only its kernel name changes. Moving the drive detaches it from every consumer – operator's choice.
  local disks_json="${LIVE_HDIDLE_DISKS_JSON:-}"
  if [ "$disks_json" = "" ]; then
    echo "-- rename scenario skipped: no managed drives in this run (set LIVE_HDIDLE_LABEL_GLOB so live_prepare includes drives)"
    return 0
  fi
  local selector="${LIVE_HDIDLE_RENAME_DISK:-}" rename_disk rename_label rename_dev rename_byid old_name new_name
  local logs after_change final_segment cmd_line expected pm_pattern pattern disk link_target
  local detected=0 found=0 spun_seen=0 wait_start rename_delay
  local -a argv=() managed_arr=()
  local -r poll=15
  local -r rename_timeout="${LIVE_HDIDLE_RENAME_TIMEOUT:-1800}"
  local -r restart_window=180 event_window=420
  local detect_deadline=$((SECONDS + rename_timeout)) restart_deadline event_deadline

  ## Selector: a kernel name from the discovered map, or the filesystem label of exactly one included drive.
  rename_disk=$(jq -r --arg s "$selector" 'if has($s) then $s else empty end' <<<"$disks_json")
  if [ "$rename_disk" = "" ] \
    && [ "$(jq --arg s "$selector" '[to_entries[] | select(.value.label == $s)] | length' <<<"$disks_json")" = "1" ]; then
    rename_disk=$(jq -r --arg s "$selector" 'to_entries[] | select(.value.label == $s) | .key' <<<"$disks_json")
  fi
  if [ "$rename_disk" = "" ]; then
    echo "   FAIL: rename target '$selector' is neither a managed kernel name nor the label of exactly one included drive" >&2
    return 1
  fi
  rename_dev=$(jq -r --arg d "$rename_disk" '.[$d].device' <<<"$disks_json")
  rename_byid=${rename_dev#/dev/disk/by-id/}
  rename_label=$(jq -r --arg d "$rename_disk" '.[$d].label' <<<"$disks_json")
  old_name=$rename_disk

  echo "-- port-move scenario: the watcher's end-to-end promise (hd-idle/KNOWLEDGE.md §\"hd-idle-watch design\")"
  echo "   >>> MOVE THE DRIVE NOW: unplug '$old_name' (label '$rename_label', $rename_dev) and attach it to a"
  echo "   >>> DIFFERENT port on the device. Waiting up to ${rename_timeout}s."
  echo "   (the watcher picks the change up on its next tick, <=30 s after the re-attach)"

  ## Rename detection via the configured by-id link: udev removes it while the drive is detached and re-creates
  ## it with the new target when the drive comes back; a link still naming the old kernel name keeps waiting.
  while [ "$SECONDS" -lt "$detect_deadline" ]; do
    link_target=$(ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" \
      "readlink '/dev/disk/by-id/$rename_byid' 2>/dev/null") || link_target=""
    link_target=${link_target##*/}
    if [ "$link_target" != "" ] && [ "$link_target" != "$old_name" ]; then
      new_name=$link_target
      detected=1
      wait_start=$SECONDS
      break
    fi
    sleep "$poll"
  done
  if [ "$detected" != 1 ]; then
    echo "   FAIL: no port move observed within ${rename_timeout}s (by-id link now: ${link_target:-absent})" >&2
    return 1
  fi
  echo "   rename detected: $old_name -> $new_name"

  ## Expected post-restart managed set: every managed drive under its current kernel name (the moved drive
  ## under its NEW one) – equality with this set also proves the stale name is no longer managed.
  expected=$(jq -cr --arg old "$old_name" --arg new "$new_name" \
    'keys | map(if . == $old then $new else . end) | sort | join(" ")' <<<"$disks_json")

  ## Wait for the watcher's regeneration and restart. The region is cut at the LAST "Drive device paths
  ## changed" line (the watcher logs it right before installing the candidates and restarting the hd-idle
  ## service); a service restart runs no cont-init, so the run script's "Starting hd-idle:" line – not
  ## "Configuring hd-idle..." – is the boot anchor, and it carries the full new command line.
  restart_deadline=$((wait_start + restart_window))
  while [ "$SECONDS" -lt "$restart_deadline" ]; do
    logs=$(ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" \
      "ha apps logs $LIVE_LOCAL_SLUG --boot 0 --lines 400" 2>/dev/null) || logs=""
    after_change=$(awk '/Drive device paths changed/{buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' <<<"$logs")
    final_segment=$(awk '/Starting hd-idle:/{buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' <<<"$after_change")
    if [ "$after_change" != "$logs" ] && grep -q "symlinkPolicy=" <<<"$final_segment"; then
      cmd_line=$(grep -m1 "Starting hd-idle:" <<<"$final_segment" | sed 's|^.*Starting hd-idle: /usr/sbin/hd-idle ||')
      read -ra argv <<<"$cmd_line"
      managed_arr=()
      for i in "${!argv[@]}"; do
        [ "${argv[$i]}" = "-a" ] || continue
        managed_arr+=("${argv[$((i + 1))]}")
      done
      if [ "$(printf '%s\n' "${managed_arr[@]}" | sort | paste -sd' ' -)" = "$expected" ]; then
        found=1
        rename_delay=$((SECONDS - wait_start))
        break
      fi
    fi
    sleep "$poll"
  done
  if [ "$found" != 1 ]; then
    echo "   FAIL: no hd-idle restart with the new configuration within ${restart_window}s after the rename" >&2
    echo "         (the watcher did not pick up the changed resolution?); app log tail:" >&2
    tail -15 <<<"${final_segment:-$logs}" | sed 's/^/         /' >&2
    return 1
  fi
  echo "   PASS: hd-idle restarted with the new configuration (${rename_delay}s after the rename was detected –"
  echo "         the watcher's <=30 s tick plus regeneration) and manages exactly: $expected"

  ## hd-idle-pmfix on the changed drives-file line: the renamed drive's row is NEW for --since (the unplug
  ## cycle recorded its by-id passthrough row), so its decision re-applies exactly as at boot; every
  ## unchanged drive must be skipped by the --since diff (the redundant-treatment guard). Dash-free patterns
  ## – the log strings' dash normalization must not couple the assertions to one app version.
  if [ "$(jq -r --arg d "$rename_disk" '.[$d].pm_optout // false' <<<"$disks_json")" = "true" ]; then
    pm_pattern="Drive ${new_name}: drive-PM treatment disabled for this drive"
  else
    pm_pattern="Drive ${new_name}: APM disable"
  fi
  if ! grep -qF "$pm_pattern" <<<"$after_change"; then
    echo "   FAIL: no hd-idle-pmfix decision logged for the renamed drive ('$pm_pattern ...')" >&2
    tail -10 <<<"$after_change" | sed 's/^/         /' >&2
    return 1
  fi
  echo "   PASS: hd-idle-pmfix re-evaluated the changed drives-file line ('$pm_pattern ...')"
  while IFS= read -r disk; do
    [ "$disk" != "" ] || continue
    [ "$disk" = "$old_name" ] && continue
    if [ "$(jq -r --arg d "$disk" '.[$d].pm_optout // false' <<<"$disks_json")" = "true" ]; then
      pattern="Drive ${disk}: drive-PM treatment disabled for this drive (configuration unchanged)"
    else
      pattern="Drive ${disk}: power management already disabled (unchanged configuration)"
    fi
    if ! grep -qF "$pattern" <<<"$after_change"; then
      echo "   FAIL: no --since skip line for the unchanged drive ${disk} ('$pattern ...')" >&2
      echo "         (it must NOT be re-treated on a mere rename of another drive)" >&2
      return 1
    fi
  done < <(jq -r 'keys[]' <<<"$disks_json")
  echo "   PASS: --since skipped every unchanged drive (no redundant re-treatment)"

  ## The crown assertion: a daemon-issued spindown under the NEW kernel name proves the whole device-access
  ## chain (cgroup rules re-granted on hotplug, AppArmor SG_IO mediation, the node inside the container)
  ## kept working across the port move without an app restart.
  event_deadline=$((SECONDS + event_window))
  echo "-- waiting for a daemon-issued spindown of $new_name (idle 30 s, window ${event_window}s)"
  while [ "$SECONDS" -lt "$event_deadline" ]; do
    logs=$(ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" \
      "ha apps logs $LIVE_LOCAL_SLUG --boot 0 --lines 400" 2>/dev/null) || logs=""
    after_change=$(awk '/Drive device paths changed/{buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' <<<"$logs")
    if grep -q "${new_name} spindown" <<<"$after_change"; then
      spun_seen=1
      break
    fi
    sleep "$poll"
  done
  if [ "$spun_seen" != 1 ]; then
    echo "   FAIL: no spindown event for $new_name within ${event_window}s of the rename pickup" >&2
    echo "         (device access not re-granted on hotplug? drive busy/no idle time?)" >&2
    return 1
  fi
  echo "   PASS: spindown event under the new kernel name – the device-access chain (cgroup rules plus"
  echo "         AppArmor) kept working across the port move without an app restart"
  return 0
}
