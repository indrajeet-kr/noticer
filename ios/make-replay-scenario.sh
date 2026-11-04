#!/bin/sh
# Build the water-table replay scenarios from real glasses frames.
#
# The user drops frames into fixtures/keyframes/water-table/ (0001.jpg, ...
# in time order) with an optional verdicts.json mapping file names to
# {"t": seconds}:
#
#   { "0007.jpg": {"t": 4.0}, "0012.jpg": {"t": 6.5} }
#
# Extra keys per frame (recorded verdict notes, labels) are ignored: the
# scripted responses in the scenario files stay authored. Without
# verdicts.json, frames take t = 0, 2, 4, ... (one sample_every step apart).
#
# This script downsizes every frame (long edge 640, about 40 KB, EXIF/GPS
# stripped) and rewrites only the "frames" arrays of the three
# fixtures/scenarios/water-table-*.json files. With no frames it does
# nothing and exits 0; the app then hides those scenarios.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/fixtures/keyframes/water-table"
SCEN="$ROOT/fixtures/scenarios"

if ! ls "$DIR"/0*.jpg >/dev/null 2>&1; then
    echo "No frames in $DIR; nothing to do."
    exit 0
fi

if python3 -c "import PIL.Image" 2>/dev/null; then
    python3 - "$DIR" <<'EOF'
import glob, os, sys
from PIL import Image

d = sys.argv[1]
for path in sorted(glob.glob(os.path.join(d, "0*.jpg"))):
    img = Image.open(path).convert("RGB")
    img.thumbnail((640, 640), Image.LANCZOS)
    data = None
    for quality in (70, 60, 50, 40, 30):
        import io
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=quality, optimize=True)
        data = buf.getvalue()
        if len(data) <= 45 * 1024:
            break
    with open(path, "wb") as f:
        f.write(data)
    print(f"{os.path.basename(path)}: {img.size[0]}x{img.size[1]} {len(data) // 1024}KB")
EOF
elif command -v sips >/dev/null 2>&1; then
    echo "Pillow not found; resizing with sips (EXIF may remain, install pillow to strip it)."
    for f in "$DIR"/0*.jpg; do
        sips -Z 640 -s format jpeg "$f" >/dev/null
    done
else
    echo "Need python3+Pillow or sips to process frames." >&2
    exit 1
fi

python3 - "$DIR" "$SCEN" <<'EOF'
import glob, json, os, sys

d, scen = sys.argv[1], sys.argv[2]
files = sorted(os.path.basename(p) for p in glob.glob(os.path.join(d, "0*.jpg")))
times = {}
vpath = os.path.join(d, "verdicts.json")
if os.path.exists(vpath):
    with open(vpath) as f:
        verdicts = json.load(f)
    for name, entry in verdicts.items():
        if isinstance(entry, dict) and "t" in entry:
            times[name] = float(entry["t"])
frames = []
for index, name in enumerate(files):
    t = times.get(name, float(index * 2))
    frames.append({"t": int(t) if t.is_integer() else t, "image": f"water-table/{name}"})
frames.sort(key=lambda e: e["t"])
for scenario in ("water-table-whisper", "water-table-self-catch", "water-table-she-handled-it"):
    path = os.path.join(scen, f"{scenario}.json")
    with open(path) as f:
        data = json.load(f)
    data["frames"] = frames
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"{scenario}.json: {len(frames)} frames")
EOF

total=$(du -sk "$DIR" | cut -f1)
echo "water-table total: ${total}KB (budget 5120KB)"
