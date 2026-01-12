#!/usr/bin/env bash
set -euo pipefail

# fix-time.sh — robust time fix for Debian snapshots/VPS
# - Prefer systemd-timesyncd (NTP UDP/123, no TLS dependency)
# - If NTP sync fails, fallback to HTTP Date header (plain HTTP) to bootstrap time
# - Finally write system time back to RTC if available

LOG_PREFIX="[fix-time]"
TIMEOUT_SEC="${TIMEOUT_SEC:-60}"
HTTP_BOOTSTRAP_URL="${HTTP_BOOTSTRAP_URL:-http://neverssl.com/}"   # plain HTTP, has Date header
NTP_SERVERS="${NTP_SERVERS:-time.cloudflare.com time.google.com pool.ntp.org}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "$LOG_PREFIX please run as root (sudo)" >&2
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

info() { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX WARNING: $*" >&2; }

ensure_timesyncd() {
  if ! systemctl list-unit-files | grep -q '^systemd-timesyncd\.service'; then
    warn "systemd-timesyncd not found. On Debian 12 it should exist. Installing systemd-timesyncd..."
    apt-get update -y || true
    apt-get install -y systemd-timesyncd || true
  fi
}

configure_timesyncd_servers() {
  local conf="/etc/systemd/timesyncd.conf"
  mkdir -p /etc/systemd
  if [[ ! -f "$conf" ]]; then
    cat >"$conf" <<EOF
[Time]
NTP=$NTP_SERVERS
FallbackNTP=pool.ntp.org
EOF
    info "created $conf with NTP servers: $NTP_SERVERS"
  else
    # Ensure [Time] exists and NTP line present; avoid over-editing user configs
    if ! grep -q '^\[Time\]' "$conf"; then
      printf "\n[Time]\n" >>"$conf"
    fi
    if grep -q '^NTP=' "$conf"; then
      sed -i "s/^NTP=.*/NTP=$NTP_SERVERS/" "$conf"
    else
      sed -i "/^\[Time\]/a NTP=$NTP_SERVERS" "$conf"
    fi
    if ! grep -q '^FallbackNTP=' "$conf"; then
      sed -i "/^\[Time\]/a FallbackNTP=pool.ntp.org" "$conf"
    fi
    info "updated $conf with NTP servers: $NTP_SERVERS"
  fi
}

restart_time_services() {
  timedatectl set-ntp true >/dev/null 2>&1 || true
  systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true
  systemctl restart systemd-timesyncd.service >/dev/null 2>&1 || true
}

is_synced() {
  # Works on systemd
  local v
  v="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "no")"
  [[ "$v" == "yes" ]]
}

wait_for_sync() {
  local start end now
  start="$(date +%s)"
  end=$((start + TIMEOUT_SEC))
  while true; do
    if is_synced; then
      return 0
    fi
    now="$(date +%s)"
    if (( now >= end )); then
      return 1
    fi
    sleep 2
  done
}

http_bootstrap_time() {
  info "NTP not synced within ${TIMEOUT_SEC}s. Trying HTTP Date bootstrap from: $HTTP_BOOTSTRAP_URL"

  local date_hdr=""
  if has_cmd curl; then
    date_hdr="$(curl -sI "$HTTP_BOOTSTRAP_URL" | awk -F': ' 'tolower($1)=="date"{print $2}' | tail -n1 || true)"
  elif has_cmd wget; then
    # wget prints headers to stderr with -S; capture both
    date_hdr="$(wget -qSO- "$HTTP_BOOTSTRAP_URL" 2>&1 | awk -F': ' 'tolower($1)=="  date"{print $2}' | tail -n1 || true)"
  else
    warn "neither curl nor wget found; cannot HTTP bootstrap"
    return 1
  fi

  if [[ -z "$date_hdr" ]]; then
    warn "could not obtain HTTP Date header"
    return 1
  fi

  info "HTTP Date: $date_hdr"
  # Set UTC time from header
  date -u -s "$date_hdr" >/dev/null 2>&1 || { warn "failed to set time from HTTP header"; return 1; }
  return 0
}

write_hwclock() {
  if ! has_cmd hwclock; then
    warn "hwclock not available; skipping RTC sync"
    return 0
  fi
  # If /dev/rtc not present (some containers), skip
  if [[ ! -e /dev/rtc && ! -e /dev/rtc0 ]]; then
    warn "RTC device not present; skipping RTC sync"
    return 0
  fi

  # Ensure RTC is treated as UTC (recommended)
  timedatectl set-local-rtc 0 >/dev/null 2>&1 || true

  # Write system time to RTC
  hwclock --systohc --utc >/dev/null 2>&1 || hwclock --systohc >/dev/null 2>&1 || {
    warn "failed to write system time to RTC"
    return 1
  }
  info "wrote system time to RTC (hwclock --systohc)"
  return 0
}

show_status() {
  info "timedatectl summary:"
  timedatectl || true
  info "date:"
  date || true
  if has_cmd hwclock; then
    info "hwclock:"
    hwclock || true
  fi
}

install_systemd_service() {
  local script_path="/usr/local/sbin/fix-time"
  local unit_path="/etc/systemd/system/fix-time.service"

  if [[ "$(realpath "$0")" != "$script_path" ]]; then
    info "installing script to $script_path"
    install -m 0755 "$0" "$script_path"
  fi

  cat >"$unit_path" <<'EOF'
[Unit]
Description=Fix system time after snapshot/boot (NTP + fallback bootstrap)
Wants=network-online.target
After=network-online.target systemd-timesyncd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fix-time

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable fix-time.service
  info "installed and enabled systemd service: fix-time.service"
  info "you can run it now with: systemctl start fix-time.service"
}

main() {
  need_root

  case "${1:-run}" in
    run)
      ensure_timesyncd
      configure_timesyncd_servers
      restart_time_services

      if wait_for_sync; then
        info "NTP synced successfully."
      else
        warn "NTP sync timeout."
        if http_bootstrap_time; then
          info "bootstrapped time via HTTP; retrying NTP sync..."
          restart_time_services
          wait_for_sync || warn "still not NTP-synced (but system time is bootstrapped)"
        else
          warn "HTTP bootstrap failed; leaving time as-is"
        fi
      fi

      write_hwclock || true
      show_status
      ;;
    --install-service)
      install_systemd_service
      ;;
    *)
      echo "Usage:"
      echo "  $0                # run once"
      echo "  $0 run            # run once"
      echo "  $0 --install-service  # install as systemd oneshot at boot"
      exit 2
      ;;
  esac
}

main "$@"
