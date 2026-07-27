# HTUSBTools.dll binary patch

`Ampero II Setup` V1.5.1 ships a closed-source native plugin, `HTUSBTools.dll`,
that reassembles incoming SysEx (MIDI) messages. Its continuation-chunk path
dereferences a buffer pointer with no null check, which crashes the whole app
if a continuation-flagged chunk ever arrives while no message is in progress
(easy to trigger under Proton's faster thread scheduling). Full root-cause
writeup: see `../../docs/STATUS.md`, "Bug #4b".

`apply_patch.py` fixes this by writing two small null-checks into unused
zero-padding at the end of the DLL's `.text` section (a "code cave" — no new
section, no relocation changes). It only ever touches a file whose bytes at
the target offsets exactly match the known original V1.5.1; anything else
(different version, already patched, corrupted download) makes it refuse and
do nothing. It always writes a `.orig-backup` copy before patching.

## Why this isn't just included pre-patched

`HTUSBTools.dll` is Hotone's proprietary binary, not ours to redistribute —
patched or not. This repo ships only the *patch*, which you apply to your own
legitimately-installed copy. This is the same relationship as a Linux
distro's patch to a proprietary codec: the diff is free to share, the
underlying binary is not ours to give out.

## Usage

Install the real `Ampero II Setup` V1.5.1 into your Wine prefix first (see
`../../build/setup-prefix.sh`), then run:

```sh
python3 apply_patch.py "$WINEPREFIX/drive_c/Program Files/Hotone/Ampero II/assets/HTUSBTools.dll"
python3 apply_patch.py "$WINEPREFIX/drive_c/Program Files/Hotone/Ampero II/data/flutter_assets/assets/HTUSBTools.dll"
```

Both copies inside a V1.5.1 install need patching — the app loads whichever
one Flutter's asset bundle resolves to, and it has been observed to be either.
