#!/usr/bin/env bash
set -euo pipefail
systemctl disable --now hostwatch.timer || true
rm -f /etc/systemd/system/hostwatch.service
rm -f /etc/systemd/system/hostwatch.timer
systemctl daemon-reload
rm -f /usr/local/bin/hostwatch.sh
rm -rf /etc/hostwatch
rm -rf /var/lib/hostwatch
echo "HostWatch removido."

