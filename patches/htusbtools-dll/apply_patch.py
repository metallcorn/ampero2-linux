#!/usr/bin/env python3
"""
Binary patch for HTUSBTools.dll from Hotone "Ampero II Setup" V1.5.1 for Windows.

Fixes a real null-pointer-dereference crash in Hotone's own closed-source code
(HTMIDIDevice::handleIncomingMidiMessage's SysEx reassembly): a "continuation"
chunk arriving while no message is in progress dereferences a NULL buffer
pointer both inside the internal putData() function and in its caller,
crashing the whole app. This patch adds two null-checks via small code caves
written into unused zero-padding at the end of the .text section (between
its VirtualSize and the next section's file offset) - no relocation or
section-table changes needed.

Usage:
    python3 htusbtools_v151_patch.py "/path/to/Program Files/Hotone/Ampero II/assets/HTUSBTools.dll"
    python3 htusbtools_v151_patch.py "/path/to/.../data/flutter_assets/assets/HTUSBTools.dll"

Both copies inside a V1.5.1 install need patching (run the script twice, once
per path, or pass both paths on one command line).

Only ever patches a file whose bytes at the target offsets exactly match the
known original V1.5.1 - if they don't match (different version, already
patched, or a corrupted download) it refuses and does nothing. A ".orig-backup"
copy is always made alongside the original before writing.

This script only modifies a copy of Hotone's DLL that YOU already legitimately
downloaded and installed - it is not a redistribution of their code.
"""
import sys
import shutil
import struct

# ---- offsets are specific to Ampero II Setup V1.5.1's HTUSBTools.dll ----
ENTRY_OFF = 0x4ca40
CAVE1_OFF = 0x176c3c
CALLER_OFF = 0xcd798
CAVE2_OFF = 0x176c60

ENTRY_EXPECTED = bytes.fromhex("405556574154415541564157")
ENTRY_PATCH = bytes.fromhex("e9f7a1120090909090909090")
CAVE1_PATCH = bytes.fromhex("4885c9750331c0c3405556574154415541564157e9f75dedff")

CALLER_EXPECTED = bytes.fromhex("498b0ee8a0f2f7ff")
CALLER_PATCH = bytes.fromhex("e9c3940a00909090")
# Retries up to 30x Sleep(1) via the DLL's own imported Sleep() before giving up
# and jumping to the function's shared cleanup/return path. This is the exact
# byte sequence that was verified working (crash-free) in the live test session.
CAVE2_PATCH = bytes.fromhex(
    "41ba1e000000498b0e4885c975194152b901000000ff158d080000415a41ffca75e4"
    "e9936ef5ffe8b45dedffe90f6bf5ff"
)


def patch_one(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    entry_cur = bytes(data[ENTRY_OFF:ENTRY_OFF + len(ENTRY_EXPECTED)])
    caller_cur = bytes(data[CALLER_OFF:CALLER_OFF + len(CALLER_EXPECTED)])
    cave1_cur = bytes(data[CAVE1_OFF:CAVE1_OFF + len(CAVE1_PATCH)])
    cave2_cur = bytes(data[CAVE2_OFF:CAVE2_OFF + len(CAVE2_PATCH)])

    if entry_cur == ENTRY_PATCH and caller_cur == CALLER_PATCH:
        print(f"[skip] {path}: already patched.")
        return True

    if entry_cur != ENTRY_EXPECTED:
        print(f"[FAIL] {path}: unexpected bytes at entry offset {ENTRY_OFF:#x} "
              f"(got {entry_cur.hex()}, expected {ENTRY_EXPECTED.hex()}). "
              f"Not V1.5.1, or already modified some other way. Aborting.")
        return False
    if caller_cur != CALLER_EXPECTED:
        print(f"[FAIL] {path}: unexpected bytes at caller offset {CALLER_OFF:#x}. Aborting.")
        return False
    if any(b != 0 for b in cave1_cur) or any(b != 0 for b in cave2_cur):
        print(f"[FAIL] {path}: code-cave space isn't zero-filled as expected. Aborting.")
        return False

    backup = path + ".orig-backup"
    shutil.copy2(path, backup)
    print(f"[ok]   backed up original to {backup}")

    data[ENTRY_OFF:ENTRY_OFF + len(ENTRY_PATCH)] = ENTRY_PATCH
    data[CAVE1_OFF:CAVE1_OFF + len(CAVE1_PATCH)] = CAVE1_PATCH
    data[CALLER_OFF:CALLER_OFF + len(CALLER_PATCH)] = CALLER_PATCH
    data[CAVE2_OFF:CAVE2_OFF + len(CAVE2_PATCH)] = CAVE2_PATCH

    with open(path, "wb") as f:
        f.write(data)
    print(f"[ok]   patched {path}")
    return True


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    ok = True
    for p in sys.argv[1:]:
        ok = patch_one(p) and ok
    sys.exit(0 if ok else 1)
