#!/bin/sh
# Pull saved Muse-call frames off the connected iPhone.
# Usage: ./pull-frames.sh [DEVICE_ID]
# Falls back to the first connected device from `devicectl list devices`.
set -eu
DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
    DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27,}' | head -n 1 || true)"
fi
if [ -z "$DEVICE" ]; then
    echo "No device id given and none found. Plug in the phone, unlock it, then retry:" >&2
    echo "  ./pull-frames.sh YOUR_DEVICE_ID" >&2
    exit 1
fi
OUT="$HOME/noticer-frames"
mkdir -p "$OUT"
xcrun devicectl device copy from \
    --device "$DEVICE" \
    --domain-type appDataContainer \
    --domain-identifier app.noticer.Noticer \
    --source Documents/FrameCapture \
    --destination "$OUT/FrameCapture"
echo "Saved $OUT/FrameCapture (device $DEVICE)"
