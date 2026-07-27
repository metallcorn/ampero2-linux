# ampero2-linux

Patches and build scripts to run Hotone's **Ampero II Setup** (the editor for
the Ampero II Stage pedal, USB `84ef:0053`) on Linux via Wine/Proton.

This repo ships **only code**: Wine source patches, a binary-patch script,
and build/launch scripts. It does **not** ship Wine/Proton binaries, Hotone's
proprietary `HTUSBTools.dll`, or the Ampero II Setup installer itself — you
build/install those yourself from official sources, and these scripts glue
the result together. See "Why not just share the whole thing" below.

## Status

The app **works end-to-end** with these patches: renders correctly, browses
Hotone's online Community, never crashes. Connecting to the pedal itself has
one **known, unresolved flake**: the startup handshake with the pedal
occasionally drops a reply and never recovers on its own, so the app sits on
"No Device Connected" — success rate measured between roughly 20% and 90%
per launch, for reasons narrowed down but not fully root-caused (see
`docs/STATUS.md` and `docs/INVESTIGATION.md`). `launch/launch.sh` ships an
automatic detect-and-retry wrapper as the practical mitigation.

## Requirements

- Linux x86_64 with a graphical session (X11 or XWayland).
- Steam, with **Proton - Experimental** installed (free, via Steam's Tools
  list or any game's Compatibility settings) — used as the patched-driver
  base, since it has a working DXVK/winex11 integration out of the box.
- A normal Wine build toolchain to compile the two patched drivers (gcc,
  flex, bison, the X11/ALSA/etc dev headers Wine needs, 32-bit multilib for
  `--enable-archs=i386,x86_64`). See winehq.org for your distro's package
  list if `build/build-wine.sh` fails on a missing dependency.
- Your own legitimately-obtained copy of the "Ampero II Setup" installer
  (from Hotone) — this repo cannot provide it.
- Python 3, for the `HTUSBTools.dll` patcher.

## Quick start

```sh
git clone git@github.com:metallcorn/ampero2-linux.git
cd ampero2-linux

# 1. Build the two patched Wine drivers (clones wine-mirror at the matching
#    tag, applies patches/, builds). Output goes to build/out/.
./build/build-wine.sh

# 2. Copy a private Proton + create a WINEPREFIX, install the patched drivers.
./build/setup-prefix.sh

# 3. Install the official installer into the prefix (path printed by step 2),
#    then patch the two HTUSBTools.dll copies it drops (fixes a real
#    null-deref crash in Hotone's own code, see docs/STATUS.md Bug #4b):
python3 patches/htusbtools-dll/apply_patch.py \
    "$HOME/.local/share/ampero2-linux/prefix/drive_c/Program Files/Hotone/Ampero II/assets/HTUSBTools.dll" \
    "$HOME/.local/share/ampero2-linux/prefix/drive_c/Program Files/Hotone/Ampero II/data/flutter_assets/assets/HTUSBTools.dll"

# 4. Run it.
./launch/launch.sh
```

`launch.sh` retries the startup automatically (see "Known issues" below).
Knobs, all optional env vars: `AMPERO_ATTEMPTS` (default 10, set to `1` to
disable the wrapper), `AMPERO_CONNECT_TIMEOUT` (45s), `AMPERO_STALL_GRACE`
(15s).

## What's in here

| Path | What |
| --- | --- |
| `patches/0001-wineusb-register-device-interfaces.patch` | Fixes Wine's `wineusb.sys` never registering USB device-arrival interfaces, so apps that gate "device present" on that (this one does) never see the pedal. |
| `patches/0002-alsamidi-sysex-fix-throttle-trace.patch` | Fixes SysEx message-boundary handling in `winealsa.drv`, a required inter-chunk throttle, a `midi_in_close` race (stale notification delivered after close), and adds optional trace logging used by `tools/match-replies.py`. |
| `patches/htusbtools-dll/apply_patch.py` | Binary-patches **your own** installed `HTUSBTools.dll` (V1.5.1) to fix a real null-pointer-dereference crash in Hotone's own code. Refuses to touch anything that doesn't match the known original bytes. |
| `build/build-wine.sh` | Clones Wine at the tag matching Proton's unixlib ABI, applies the two patches above, builds. |
| `build/setup-prefix.sh` | Copies a local Proton - Experimental install, drops in the built drivers, creates a WINEPREFIX. |
| `launch/launch.sh` | Runs the app; retries automatically on a detected handshake stall. |
| `tools/match-replies.py` | Decodes a wire-level MIDI capture (`aseqdump`) and Wine's trace log, tells you whether a given stall is a lost reply on the wire or something dropped after Wine received it. |
| `tools/handshake-trials.sh` | Alternates two configurations trial-by-trial to test a hypothesis about the connection flake, avoiding the false leads documented in `docs/INVESTIGATION.md`. |
| `dev-tools/winedbg-memdump-debug-aid.patch` | Optional `winedbg` convenience (adds a memory-dump command) used during earlier debugging. Not required to build or run anything. |
| `docs/STATUS.md`, `docs/INVESTIGATION.md` | Full technical history: every bug found, what was tried and rejected, and why. Read before re-investigating the remaining flake. |

## Fixed issues (already handled by the patches/scripts above)

- **USB device-arrival not detected** — Wine's `wineusb.sys` gap (patch 0001).
- **Crash on SysEx continuation with no message in progress** — `HTUSBTools.dll`
  null-deref, fixed by the binary patch, plus a Wine-side mitigation that
  makes it much less likely to be hit at all (patch 0002).
- **Intermittent crash under Proton's faster thread scheduling** — same fix.
- **Fails to launch at all on hosts with no 32-bit runtime** (`/lib/ld-linux.so.2:
  could not open`) — the bundled/built Proton is an old-style WoW64 build that
  unconditionally re-execs its 32-bit loader even for this pure-64-bit app.
  `launch.sh` detects a missing i386 loader and drives the 64-bit loader
  directly with `WINELOADERNOEXEC=1`. Confirmed fixed on a second machine with
  no i386 packages installed at all.

## Known open issue

The pedal-connection handshake drops a reply occasionally and the app never
retries it, so it sits on "No Device Connected" forever. Proven (via a
byte-for-byte wire-vs-Wine comparison) to **not** be the pedal, ALSA, or
Wine's driver — the reply arrives complete and correct, and Wine hands it to
the app; the drop happens inside Hotone's own closed-source Dart/Flutter
code. Success rate drifts 20%-90% run to run for reasons not pinned down —
see `docs/STATUS.md` (Bug #5) and `docs/INVESTIGATION.md` for the full
evidence trail and the several plausible-looking theories that did not
survive re-testing. `launch.sh`'s retry wrapper is the practical mitigation;
a real fix would need reverse-engineering Hotone's compiled Dart AOT code,
which has not been attempted.

## Why not just share the whole thing (Proton + prefix + app)

- Proton is Valve's build, not ours to redistribute wholesale.
- Hotone's installer and `HTUSBTools.dll` are proprietary — patched or not,
  redistributing them is a different legal situation than sharing a patch you
  apply to your own legitimately-installed copy.
- It's ~1.5GB+ compressed; a git repo of just patches and scripts is a much
  better fit for GitHub and for reviewing changes over time.

## License

MIT for the scripts and patch code in this repo (see `LICENSE`). The two
Wine patches are diffs against Wine (LGPL-2.1) intended for eventual
upstream submission; applying them to your own Wine build is unaffected by
this repo's license. `HTUSBTools.dll` itself is Hotone's proprietary
software and is not covered by (or included in) this repo at all.
