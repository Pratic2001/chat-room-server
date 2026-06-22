#!/usr/bin/env bash
# ensure-buildkit.sh — idempotently make sure buildkitd is running and
# reachable on a known socket. Safe to run on every Jenkins build.
#
# Two modes:
#   1. System-mode buildkitd (apt install buildkitd, runs as a systemd
#      service bound to unix:///run/buildkit/buildkitd.sock). If that
#      socket exists, we just verify it answers and exit.
#   2. User-mode fallback: start a private buildkitd under the current
#      user if no system socket is found. Logs to /var/log/buildkitd.log.
set -euo pipefail

SYSTEM_SOCK="/run/buildkit/buildkitd.sock"
USER_SOCK="/run/user/$(id -u)/buildkit/buildkitd.sock"

probe() {
  local addr="$1"
  if buildctl --addr "$addr" debug workers >/dev/null 2>&1; then
    echo "buildkitd is reachable at $addr"
    return 0
  fi
  return 1
}

if [[ -S "$SYSTEM_SOCK" ]] && probe "unix://$SYSTEM_SOCK"; then
  exit 0
fi

if [[ -S "$USER_SOCK" ]] && probe "unix://$USER_SOCK"; then
  exit 0
fi

# Neither socket is up. Try to start a system buildkitd via systemctl
# (this works if the apt package was installed and the service is
# enabled). If systemctl isn't available, fall back to a foreground
# background launch bound to the system socket.
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files buildkitd.service >/dev/null 2>&1; then
    echo "starting buildkitd via systemctl..."
    sudo -n systemctl enable --now buildkitd || true
    sleep 2
    if probe "unix://$SYSTEM_SOCK"; then
      exit 0
    fi
  fi
fi

# Last-ditch: launch a user-mode buildkitd in the background.
mkdir -p "$(dirname "$USER_SOCK")" /var/log
echo "starting user-mode buildkitd, logs at /var/log/buildkitd.log"
nohup buildkitd --addr "unix://$USER_SOCK" >/var/log/buildkitd.log 2>&1 &
sleep 2
probe "unix://$USER_SOCK"
