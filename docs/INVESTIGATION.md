# Investigation notes — porting this bundle to a non-SteamOS host

Written for whoever built this bundle. Two separate problems were found while
getting it to run on a second machine. The first is fixed. The second is not,
and the important content here is the **evidence that narrows it** plus the
**hypotheses that looked right and then died**, so that work is not repeated.

Host used throughout:

| | |
| --- | --- |
| Distro | KDE neon 24.04 (Ubuntu noble), x86_64 |
| Session | Wayland, app runs via XWayland |
| GPU | AMD Radeon (RADV REMBRANDT), radv 25.2.8, DXVK 3.0.1 |
| CPU | 16 threads, governor `powersave`, driver `amd-pstate-epp` |
| i386 runtime | **absent** (`dpkg --print-foreign-architectures` empty) |
| Pedal | `84ef:0053 Hotone Audio Ampero II Stage MIDI`, ALSA `hw:5,0,0`, seq port `36:0` |

Anything below stated as measured was measured on this host. Nothing was
re-verified on SteamOS.

---

## Problem 1 — the bundle could not launch at all. Fixed.

`./launch.sh` died immediately, before any Wine output:

```
/lib/ld-linux.so.2: could not open
```

That message comes from Wine's **32-bit** preloader, which maps the ELF
interpreter itself. `strace` shows why it was even running — the first thing
Wine does is re-exec into the i386 loader:

```
execve("proton/lib/wine/x86_64-unix/wine64", ["...wine64", "cmd", "/c", "echo hi"]) = 0
execve(".../proton/lib/wine/i386-unix/wine-preloader",
       [".../i386-unix/wine-preloader", ".../i386-unix/wine", "cmd", "/c", "echo hi"]) = 0
```

Note this happens even when launching a pure x86-64 target, and even when the
64-bit loader is invoked directly. It is not conditional on the target's
bitness. This is an old-style WoW64 build: `lib/wine/i386-unix/ntdll.so` exists,
so the 32-bit loader is the canonical entry point and the host must be able to
run it. `wine --version` worked, which is misleading — that path returns before
the re-exec.

Facts established:

- `Ampero II.exe` is `PE32+ executable (GUI) x86-64` — the 32-bit half is not
  needed for the app itself.
- `proton/lib/wine/i386-unix/wine` needs only `libc.so.6` (32-bit), and
  `i386-unix/ntdll.so` likewise. So `libc6:i386` alone would have been enough.
- The prefix did not need updating (`prefix/.update-timestamp` already matches
  `proton/share/wine/wine.inf`, both `1782059078`), so `wineboot` was not the
  thing pulling in the 32-bit side.
- The build *does* ship `wow64.dll`, `wow64cpu.dll` and `wow64win.dll` in
  `lib/wine/x86_64-windows/`. Forcing new-style WoW64 by hiding
  `i386-unix/ntdll.so` was considered and **not attempted** — in an old-wow64
  build `i386-windows/ntdll.dll` is the counterpart of the 32-bit unix library,
  not the pure-PE one new-wow64 wants, so it is unlikely to simply work. Worth a
  look if you want the bundle to drop its 32-bit dependency properly.

The fix in `launch.sh` avoids the 32-bit path instead of satisfying it:

```sh
LOADER="$HERE/proton/lib/wine/x86_64-unix/wine64"
export WINELOADER="$LOADER"
export WINELOADERNOEXEC=1
```

`WINELOADERNOEXEC=1` is what actually matters — it makes Wine skip the
re-exec/preloader step and stay in the process it is already in. Setting
`WINELOADER` alone does **not** help; that was tried and still re-execed into
i386. The branch only triggers when no i386 loader is present, so SteamOS keeps
the original code path byte for byte.

Verified: `wine64 cmd /c echo` works, the app launches, DXVK initialises on
RADV, and the app reaches a working session with the pedal.

---

## Problem 2 — Bug #5. Not fixed, but substantially narrowed.

### The README's description of this bug is wrong in three ways

The old text said: the pedal occasionally doesn't respond to *one specific*
address, and it connects within 1-2 tries essentially always. Measured here:

1. **It is not one address.** Stalls landed on `1080000` (most often),
   `1000000`, and `300000a`.
2. **The pedal does respond.** See below — this is the important one.
3. **It is not 1-2 tries.** The per-launch success rate ranged from 20% to 90%
   depending on *when* the series ran.

### The pedal is not at fault, and neither is ALSA

Captured the pedal's MIDI output with `aseqdump -p 36:0` alongside the app's own
log, then matched requests to replies by decoding the address out of the SysEx.
The framing, indexed from just after the `F0 21 25 4D 50` header:

```
idx 3    0x11 = request from host, 0x12 = reply from pedal
idx 6-7  chunk offset, 00 00 on the first chunk of a reply
idx 9-15 28-bit address, one nibble per byte, little-endian
```

Confirmed against known pairs: `idx13=09` → `0x90000`; `idx9=01, idx15=03` →
`0x3000001`; `idx13=08, idx15=01` → `0x1080000`.

For a stall on `1080000`, the reply is on the wire **in full**: 15 chunks at
offsets 0, 185, 370, 555 … 2590 — a constant stride of 185 with no gaps, about
2775 bytes, properly terminated with `F7`. For a stall on `300000a`, the wire
carried 9 replies while the app parsed only 8, and the missing one was exactly
the stalled address.

Meanwhile ALSA is clean:

- Wine's sequencer client: `Alloc failures: 0`, input pool peak 51 of 200.
- `/proc/asound/card5/midi0`: `Overruns: 0`.
- Wine keeps handing buffers back to the app throughout the stall —
  `midi_in_add_buffer` calls continue, and buffer addresses get recycled, long
  after the request that never got answered.

**Conclusion: the reply arrives at the machine intact and is lost above ALSA**,
either in Wine's MIDI-in path or in the app. One detail that may matter: the app
queues its MIDI input in buffers of only **112 bytes** (`midi_in_prepare (0003,
0x…, 112)`), so every one of these multi-hundred-byte replies has to be
reassembled across many buffers.

Since the app never retries an address it lost, a single dropped reply hangs the
handshake forever. That is the whole user-visible bug.

### Hypotheses that were tested and rejected

Every one of these looked convincing in one paired series and then failed to
replicate. Recorded so nobody re-runs them.

| Hypothesis | Why it looked right | What killed it |
| --- | --- | --- |
| Wine MIDI tracing slows the path enough to fix it | first success of the day happened to be a `WINEDEBUG=+midi,+alsa` run | paired series: **2/10 with tracing vs 4/10 without** — if anything worse |
| A second ALSA-seq subscriber on the pedal port changes delivery | a series with `aseqdump` attached went **7/8** | paired series: **5/10 with vs 7/10 without** |
| Background CPU load starves the app and causes the drop | paired series: **3/10 under 4 busy cores vs 9/10 idle**, which is significant | three later runs under the *same* load connected **3/3 on the first attempt** |
| Deep C-states / low clocks on an idle machine (user's guess) | plausible given `powersave` + `amd-pstate-epp` | the CPU-load series pointed the opposite way, and that series then failed to replicate too |
| ALSA sequencer pool overflow on the large replies | large multi-chunk replies are exactly what fails | `Alloc failures: 0`, `Overruns: 0` |
| The mid-handshake HTTP call to `community.hotoneaudio.com.cn` blocks the Dart event loop | it fires right in the middle of the handshake | present in failing *and* succeeding runs; the URL line only appears after connecting, so it is downstream |

### What the drift actually looked like

Pooling all 68 trials chronologically, in blocks of 10, regardless of which arm
they belonged to:

```
09:29-09:35  2/10  ##........
09:36-09:41  4/10  ####......
09:46-09:50  9/10  #########.
09:50-09:54  6/10  ######....
09:54-10:00  6/10  ######....
10:01-10:04  7/10  #######...
10:05-10:09  3/8   ###.....
```

The rate moves around far more than any manipulated variable explained. Early
low numbers are consistent with cold caches (1.4 GB of Proton, the prefix, the
DXVK shader cache) but that is a *story*, not a demonstration — it was never
tested directly. Treat the mechanism as genuinely unknown.

**Methodological warning:** this non-stationarity is why three separate
conclusions were reached and then withdrawn. Do not compare a series against one
run at a different time. `tools/handshake-trials.sh` alternates the two
configurations under comparison, one trial each, precisely so drift hits both
arms equally; use it rather than rolling your own.

### What to do next

The single most valuable thing is to close the remaining fork: **Wine's MIDI-in
path, or the app?** That needs a log of exactly what Wine hands over in each
`MIM_LONGDATA` callback, compared against the wire capture.

The rebuilt `winealsa.so` looks like it already had that instrumentation —
it contains `handle_sysex_event`, `reset_sysex_seq`, `trace_sysex_chunk` and the
string `Dropping SysEx fragment with no start byte for dev %d.`. But **none of
it produces output** under `WINEDEBUG=+midi,+alsa`, and the "Dropping SysEx
fragment" message never fired during any stall. So either it is gated behind
something undocumented, or those paths are not reached.

**Blocker: the source for that rebuild is not in the bundle.** You presumably
still have it. With it, the next steps are cheap:

1. Find what enables `trace_sysex_chunk` and turn it on, or add an
   unconditional log of every `MIM_LONGDATA` payload handed to the app.
2. Reproduce a stall with `tools/handshake-trials.sh -n 10 sniff plain` and run
   `tools/match-replies.py` on a failing pair to confirm the pedal answered.
3. Compare the bytes Wine delivered against the bytes on the wire. If Wine
   delivered everything, the app is dropping it and there is nothing to fix on
   our side beyond the retry. If Wine truncated it, look first at what happens
   when a multi-buffer SysEx runs out of queued 112-byte MIDIHDRs.

Also worth checking, since it is nearly free: whether `winealsa.so.orig-backup`
(stock Wine) behaves better or worse. That was never A/B'd against the rebuild.

### Workaround currently shipped

`launch.sh` watches the app's output for `EffectChain Refresh`, and on a stall
tears the session down with `wineserver -k` and relaunches, up to
`AMPERO_ATTEMPTS` times. A stall is detected by silence rather than by the full
timeout — the app logs one `请求命令地址` line per address it asks for and simply
stops asking when a reply is lost, so `AMPERO_STALL_GRACE` seconds without a new
request means stalled. The grace default of 15s is deliberately well above the
legitimate pause from that mid-handshake HTTP call.

Verified: recovers a real failure on the second attempt; the `INT`/`TERM` trap
tears everything down cleanly; `AMPERO_ATTEMPTS=1` gives a plain `exec` with no
wrapper.

---

## Smaller findings

- **`winedmo.so` is dead on this host.** It wants the FFmpeg 4 generation
  (`libavcodec.so.58`, `libavformat.so.58`, `libavutil.so.56`); Ubuntu 24.04 has
  `libavcodec.so.60`, and the bundle ships GStreamer but no FFmpeg. The app
  never touches it, so nothing breaks today. It is the only unresolved host
  dependency in the whole 64-bit runtime — everything else in
  `proton/lib/wine/x86_64-unix/` resolved cleanly.
- **`prefix/dosdevices/com6` points at `/dev/ttyACM0`.** Harmless here, but it
  is a host-specific path baked into the prefix, in the same category as the
  embedded `deck` username already noted in the README.
- **The README points at two files that are not in the bundle**: the main
  project's `STATUS.md` (for Bug #5) and `../portable_package/README.md` (for
  updating). Neither travels with the bundle, so on a target machine both
  references are dead ends. `INVESTIGATION.md` now covers Bug #5; the update
  procedure is still only documented outside the bundle.
- The app's MIDI I/O itself is wired up correctly and was never in doubt:
  `aconnect -l` shows `WINE midi driver` bidirectionally connected to
  `Ampero II Stage MIDI`, and `scanInDevice---3 / scanOutDevice---3` in the log.
- A successful handshake is 20 requests with 10-13 parsed replies, and takes
  about 3 seconds once caches are warm. `EffectChain Refresh` is a reliable
  success marker; `ConnectionStatus.connected` is **not** — the app only ever
  logs `ConnectionStatus.connecting`.
