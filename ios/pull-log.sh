#!/bin/sh
# Pull the latest Noticer session log off the connected iPhone.
# Usage: ./pull-log.sh [DEVICE_ID]
# Falls back to the first connected device from `devicectl list devices`.
set -eu
DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
    DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27,}' | head -n 1 || true)"
fi
if [ -z "$DEVICE" ]; then
    echo "No device id given and none found. Plug in the phone, unlock it, then retry:" >&2
    echo "  ./pull-log.sh YOUR_DEVICE_ID" >&2
    exit 1
fi
OUT="/tmp/noticer-latest.log"
xcrun devicectl device copy from \
    --device "$DEVICE" \
    --domain-type appDataContainer \
    --domain-identifier app.noticer.Noticer \
    --source Documents/SessionLogs/latest.log \
    --destination "$OUT"
echo "Saved $OUT (device $DEVICE)"
