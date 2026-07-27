#!/bin/bash
# Launcher for a prefix set up by ../build/setup-prefix.sh: no Steam needs to
# be running, but this does need a Proton copy + WINEPREFIX to already exist
# (point PROTON_DIR / WINEPREFIX at them, or just use the defaults that match
# setup-prefix.sh's AMPERO2_DATA_DIR).
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${AMPERO2_DATA_DIR:-$HOME/.local/share/ampero2-linux}"

export WINEPREFIX="${WINEPREFIX:-$DATA_DIR/prefix}"
PROTON_DIR="${PROTON_DIR:-$DATA_DIR/proton}"
export WINEESYNC=0
export WINEFSYNC=0

if [ ! -d "$WINEPREFIX" ] || [ ! -d "$PROTON_DIR" ]; then
    echo "launch.sh: WINEPREFIX ($WINEPREFIX) or PROTON_DIR ($PROTON_DIR) not found." >&2
    echo "           Run ../build/setup-prefix.sh first." >&2
    exit 1
fi

APP="C:\\Program Files\\Hotone\\Ampero II\\Ampero II.exe"

# The Proton build this was developed against is an old-style WoW64 build:
# "$PROTON_DIR/bin/wine" always re-execs the *32-bit* loader (lib/wine/i386-unix/wine
# via its preloader), even for a 64-bit target. On a host without 32-bit glibc
# that dies immediately with "/lib/ld-linux.so.2: could not open".
# The app is pure x86-64, so on such hosts drive the 64-bit loader directly
# and set WINELOADERNOEXEC=1 to skip the re-exec/preloader step entirely.
if [ -e /lib/ld-linux.so.2 ] || [ -e /lib32/ld-linux.so.2 ] ||
   [ -e /usr/lib32/ld-linux.so.2 ] || [ -e /lib/i386-linux-gnu/ld-linux.so.2 ]; then
    LOADER="$PROTON_DIR/bin/wine"
else
    LOADER="$PROTON_DIR/lib/wine/x86_64-unix/wine64"
    export WINELOADER="$LOADER"
    export WINELOADERNOEXEC=1
fi

# --- startup-handshake retry ------------------------------------------------
# The pedal handshake loses a reply now and then and the app has no retry for
# it, so it sits on "No Device Connected" forever (docs/STATUS.md, Bug #5).
#
# What extensive instrumented testing established (see docs/INVESTIGATION.md):
#   - the pedal always answers. On a stall its reply is on the wire, complete
#     and correctly framed (verified by decoding the address out of the SysEx
#     and matching it against the app's own request log).
#   - ALSA does not drop it either: no seq pool alloc failures, no rawmidi
#     overruns, and Wine hands buffers back to the app throughout.
#   So the reply is lost above the ALSA layer -- in Wine's MIDI-in path or in
#   the app, which queues its input in buffers of only 112 bytes. A double
#   gdb-backtrace snapshot of a live stall (6s apart, identical stacks on
#   every one of ~47 threads, none blocked on a lock another is holding)
#   points at a Dart/Flutter-level control-flow bug in Hotone's own app, not
#   a native deadlock we can fix from here.
#
# What did NOT hold up: every single-variable theory tried (MIDI tracing
# overhead, a second ALSA subscriber, background CPU load, idle C-states,
# ALSA pool sizing, the mid-handshake HTTP call, WINE_USE_KWIN_HACKS) looked
# significant in one paired series and then failed to replicate. The
# per-launch success rate genuinely drifts between roughly 20% and 90% over
# tens of minutes for reasons not pinned down, so treat it as an unsolved
# race rather than something already understood.
#
# Hence: watch for the "connected" marker and relaunch if it does not show up.
# Set AMPERO_ATTEMPTS=1 to get a single plain launch with no wrapper at all.
ATTEMPTS="${AMPERO_ATTEMPTS:-10}"
TIMEOUT="${AMPERO_CONNECT_TIMEOUT:-45}"
MARKER='EffectChain Refresh'
# A stall is recognisable long before TIMEOUT: the app logs one request line per
# address it asks the pedal for, and on a lost reply it just stops asking. If the
# request count stops moving for this long we restart instead of waiting it out.
# Kept well above a slow HTTP round-trip -- the app also contacts Hotone's server
# mid-handshake, and that pause is legitimate.
STALL_GRACE="${AMPERO_STALL_GRACE:-15}"
REQUEST_LINE='请求命令地址'   # "host sent request command, address:" in the app's log

if [ "$ATTEMPTS" -le 1 ]; then
    exec "$LOADER" "$APP" "$@"
fi

APP_PID=""
TAIL_PID=""
LOG=""

cleanup() {
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null
    [ -n "$APP_PID" ]  && kill "$APP_PID"  2>/dev/null
    return 0
}
trap 'cleanup; exit 130' INT TERM

# Ends every process in the prefix, so the next attempt starts clean.
kill_session() {
    cleanup
    "$PROTON_DIR/bin/wineserver" -k 2>/dev/null || true
    sleep 2
}

for attempt in $(seq 1 "$ATTEMPTS"); do
    LOG="$(mktemp -t ampero-launch-XXXXXX.log)"
    "$LOADER" "$APP" "$@" > "$LOG" 2>&1 &
    APP_PID=$!
    tail -f "$LOG" & TAIL_PID=$!

    connected=no
    exited=no
    stalled=no
    last_count=0
    quiet=0
    for _ in $(seq 1 "$TIMEOUT"); do
        if grep -aq "$MARKER" "$LOG" 2>/dev/null; then connected=yes; break; fi
        if ! kill -0 "$APP_PID" 2>/dev/null; then exited=yes; break; fi

        count="$(grep -ac "$REQUEST_LINE" "$LOG" 2>/dev/null || true)"
        : "${count:=0}"
        if [ "$count" -gt 0 ] && [ "$count" -eq "$last_count" ]; then
            quiet=$((quiet + 1))
            if [ "$quiet" -ge "$STALL_GRACE" ]; then stalled=yes; break; fi
        else
            quiet=0
        fi
        last_count="$count"
        sleep 1
    done

    if [ "$connected" = yes ]; then
        # Hand the session over to the user and follow the app's own exit code.
        rc=0
        wait "$APP_PID" || rc=$?
        kill "$TAIL_PID" 2>/dev/null || true
        rm -f "$LOG"
        exit "$rc"
    fi

    if [ "$exited" = yes ]; then
        echo "launch.sh: the app exited on its own during startup (attempt $attempt/$ATTEMPTS)." >&2
    elif [ "$stalled" = yes ]; then
        echo "launch.sh: handshake stalled after $last_count requests (attempt $attempt/$ATTEMPTS), restarting." >&2
    else
        echo "launch.sh: no device connection within ${TIMEOUT}s (attempt $attempt/$ATTEMPTS), restarting." >&2
    fi
    kill_session
    rm -f "$LOG"
done

echo "launch.sh: gave up after $ATTEMPTS attempts." >&2
echo "launch.sh: each attempt is independent, so simply running it again is worth a try;" >&2
echo "           raise AMPERO_ATTEMPTS to keep retrying for longer. See docs/INVESTIGATION.md." >&2
exit 1
