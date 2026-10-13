#!/bin/bash
# Builds AppIcon.icns from Resources/AppIcon-source.png (any square PNG >= 1024 px, with transparency).
# Output: .build/icon/AppIcon.icns  (inside .build, so it is never committed)
# Uses only tools that ship with macOS: sips, iconutil.
set -euo pipefail
cd "$(dirname "$0")"

SRC="Resources/AppIcon-source.png"
OUT_DIR=".build/icon"
SET="$OUT_DIR/AppIcon.iconset"

[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }

rm -rf "$OUT_DIR"
mkdir -p "$SET"

# Normalise to a 1024 master first (the source may be e.g. 1254 px)
MASTER="$OUT_DIR/master-1024.png"
sips -z 1024 1024 "$SRC" --out "$MASTER" >/dev/null

# name:pixels  (the @2x file of each size is the next size up)
for spec in \
    "icon_16x16:16" "icon_16x16@2x:32" \
    "icon_32x32:32" "icon_32x32@2x:64" \
    "icon_128x128:128" "icon_128x128@2x:256" \
    "icon_256x256:256" "icon_256x256@2x:512" \
    "icon_512x512:512" "icon_512x512@2x:1024"; do
    name="${spec%%:*}"; px="${spec##*:}"
    sips -z "$px" "$px" "$MASTER" --out "$SET/$name.png" >/dev/null
done

iconutil -c icns "$SET" -o "$OUT_DIR/AppIcon.icns"
echo "icon: $PWD/$OUT_DIR/AppIcon.icns"
