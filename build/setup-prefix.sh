#!/bin/bash
# Sets up a private, patched Proton + WINEPREFIX for Ampero II Setup, without
# touching your Steam-managed Proton install (Steam re-verifies/updates that
# on its own, which would silently discard our patched files).
#
# What this does:
#   1. Finds a local Steam "Proton - Experimental" install (or accepts one
#      via $STEAM_PROTON_DIR / -p).
#   2. Copies its files/ directory to a private location.
#   3. Drops in the wineusb.sys / winealsa.so built by build-wine.sh.
#   4. Creates a fresh WINEPREFIX and boots it once.
#
# After this, install the *official* "Ampero II Setup" installer yourself
# (get it from Hotone directly - not something this repo can provide) into
# the prefix, then run ../patches/htusbtools-dll/apply_patch.py against the
# two HTUSBTools.dll copies it installs. See ../README.md for the full flow.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
DATA_DIR="${AMPERO2_DATA_DIR:-$HOME/.local/share/ampero2-linux}"
PROTON_DEST="$DATA_DIR/proton"
PREFIX_DEST="$DATA_DIR/prefix"

usage() {
    echo "usage: $0 [-p /path/to/Proton - Experimental]" >&2
    exit 1
}

SRC_PROTON="${STEAM_PROTON_DIR:-}"
while getopts "p:h" opt; do
    case "$opt" in
        p) SRC_PROTON="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$SRC_PROTON" ]; then
    echo "==> Looking for a local Steam \"Proton - Experimental\" install..."
    for base in "$HOME/.steam/steam" "$HOME/.local/share/Steam" \
                "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        cand="$base/steamapps/common/Proton - Experimental"
        [ -d "$cand/files" ] && { SRC_PROTON="$cand"; break; }
    done
fi

if [ -z "$SRC_PROTON" ] || [ ! -d "$SRC_PROTON/files" ]; then
    cat >&2 <<'EOF'
Could not find a "Proton - Experimental" install automatically.

Install it once via Steam (Steam library -> right-click any game you own ->
Properties -> Compatibility, or just install it directly from the Steam Tools
list - it's free, published by Valve), then re-run this script with:

    ./setup-prefix.sh -p "/path/to/Steam/steamapps/common/Proton - Experimental"
EOF
    exit 1
fi

echo "==> Using Proton at: $SRC_PROTON"

if [ ! -f "$REPO_ROOT/build/out/wineusb.sys" ] || [ ! -f "$REPO_ROOT/build/out/winealsa.so" ]; then
    echo "Missing built driver files - run ./build-wine.sh first." >&2
    exit 1
fi

mkdir -p "$DATA_DIR"
if [ -d "$PROTON_DEST" ]; then
    echo "==> $PROTON_DEST already exists, reusing it (delete it first for a clean copy)"
else
    echo "==> Copying Proton's files/ to $PROTON_DEST (one-time, several GB, may take a while)"
    cp -a "$SRC_PROTON/files" "$PROTON_DEST"
fi

echo "==> Installing patched drivers"
cp -v "$REPO_ROOT/build/out/wineusb.sys" "$PROTON_DEST/lib/wine/x86_64-windows/wineusb.sys"
cp -v "$REPO_ROOT/build/out/winealsa.so" "$PROTON_DEST/lib/wine/x86_64-unix/winealsa.so"

if [ ! -d "$PREFIX_DEST" ]; then
    echo "==> Creating WINEPREFIX at $PREFIX_DEST"
    mkdir -p "$PREFIX_DEST"
    WINEPREFIX="$PREFIX_DEST" WINEESYNC=0 WINEFSYNC=0 \
        "$PROTON_DEST/bin/wine" wineboot --init
    WINEPREFIX="$PREFIX_DEST" "$PROTON_DEST/bin/wineserver" -w
else
    echo "==> $PREFIX_DEST already exists, reusing it"
fi

cat <<EOF

==> Done.
      Proton (patched): $PROTON_DEST
      WINEPREFIX:       $PREFIX_DEST

Next steps:
  1. Install the official "Ampero II Setup" installer yourself, e.g.:
       WINEPREFIX="$PREFIX_DEST" "$PROTON_DEST/bin/wine" AmperoIISetup.exe
  2. Patch the two HTUSBTools.dll copies it installs (fixes a real crash in
     Hotone's own code - see docs/STATUS.md Bug #4b):
       python3 "$REPO_ROOT/patches/htusbtools-dll/apply_patch.py" \\
           "$PREFIX_DEST/drive_c/Program Files/Hotone/Ampero II/assets/HTUSBTools.dll" \\
           "$PREFIX_DEST/drive_c/Program Files/Hotone/Ampero II/data/flutter_assets/assets/HTUSBTools.dll"
  3. Launch it:
       AMPERO2_DATA_DIR="$DATA_DIR" "$REPO_ROOT/launch/launch.sh"
EOF
