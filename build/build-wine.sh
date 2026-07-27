#!/bin/bash
# Builds a patched Wine that fixes Ampero II Setup's Linux/Proton issues:
#   - dlls/wineusb.sys:    registers USB device-arrival interfaces (Bug #1)
#   - dlls/winealsa.drv:   SysEx message-boundary fix + throttle + midi_in_close
#                          race fix (Bug #2 / #4 / #5) - see ../docs/STATUS.md
#
# Built against the wine-11.0 tag specifically because that's the unixlib ABI
# Steam's "Proton - Experimental" is based on - a .so built against a
# different Wine version can silently break MIDI device scanning with no
# error logged (see ../docs/STATUS.md, "Important ABI lesson learned").
#
# Requires a normal Wine build toolchain (gcc, flex, bison, the X11/ALSA/etc
# dev headers Wine needs, a 32-bit toolchain for --enable-archs=i386,x86_64).
# See https://www.winehq.org for your distro's "build dependencies" package
# list if `./configure` below fails with a missing-library error.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
WORKDIR="${1:-$HERE/wine-src}"
OUTDIR="$HERE/out"
WINE_TAG="wine-11.0"
WINE_REMOTE="https://github.com/wine-mirror/wine.git"

mkdir -p "$OUTDIR"

if [ ! -d "$WORKDIR/.git" ]; then
    echo "==> Cloning Wine ($WINE_TAG) into $WORKDIR (shallow, this is ~250MB)"
    git clone --depth 1 --branch "$WINE_TAG" "$WINE_REMOTE" "$WORKDIR"
else
    echo "==> Reusing existing checkout at $WORKDIR"
fi

cd "$WORKDIR"

for patch in "$REPO_ROOT"/patches/0001-*.patch "$REPO_ROOT"/patches/0002-*.patch; do
    name="$(basename "$patch")"
    if git apply --reverse --check "$patch" 2>/dev/null; then
        echo "==> $name already applied, skipping"
        continue
    fi
    echo "==> Applying $name"
    git apply --check "$patch"
    git apply "$patch"
done

if [ ! -f Makefile ]; then
    echo "==> Configuring (one-time, a couple of minutes)"
    ./configure --enable-archs=i386,x86_64
fi

echo "==> Building dlls/wineusb.sys"
make -C dlls/wineusb.sys

echo "==> Building dlls/winealsa.drv"
make -C dlls/winealsa.drv

cp -v dlls/wineusb.sys/x86_64-windows/wineusb.sys "$OUTDIR/wineusb.sys"
cp -v dlls/winealsa.drv/winealsa.so "$OUTDIR/winealsa.so"

cat <<EOF

==> Done. Built files are in $OUTDIR:
      wineusb.sys   (PE driver  - version-agnostic, safe to drop into any
                      reasonably recent Wine/Proton's
                      lib/wine/x86_64-windows/wineusb.sys)
      winealsa.so   (unix driver - must go into a Proton build whose unixlib
                      ABI matches wine-11.0, e.g. Steam's
                      "Proton - Experimental" as of 2026;
                      lib/wine/x86_64-unix/winealsa.so)

Next: run ../build/setup-prefix.sh to install these into a Proton prefix.
EOF
