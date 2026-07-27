#!/bin/bash
# Measure the pedal-connection success rate of two arms/configurations,
# alternating trials one at a time so that the drift documented in
# docs/INVESTIGATION.md (success rate genuinely wanders 20%-90% over tens of
# minutes for reasons not pinned down) hits both arms equally. Never compare
# two series run at different times - always alternate like this instead.
#
# Usage: handshake-trials.sh [-n COUNT_PER_ARM] [ARM_A] [ARM_B]
#   ARM_A/ARM_B default to "plain plain" (just measures raw variance).
#   Known arms:
#     plain  - nothing extra
#     sniff  - aseqdump attached to the pedal's MIDI port during the trial
#              (tests "does a second ALSA-seq subscriber change delivery")
#     trace  - WINEDEBUG=+midi,+alsa set for the trial
#     load   - N busy-loop background processes (N = nproc) during the trial
#     nokwin - WINE_USE_KWIN_HACKS=0 for the trial (see docs/INVESTIGATION.md:
#              the main thread was caught deadlocked inside winex11.so's
#              use_kwin_hacks()/X11DRV_HasWindowManager() during a real stall;
#              this arm tested that theory and it did not hold up)
#
# Example: handshake-trials.sh -n 10 sniff plain
set -u
DATA_DIR="${AMPERO2_DATA_DIR:-$HOME/.local/share/ampero2-linux}"
LOADER="${PROTON_DIR:-$DATA_DIR/proton}/bin/wine"
export WINEPREFIX="${WINEPREFIX:-$DATA_DIR/prefix}"
export WINEESYNC=0
export WINEFSYNC=0
APP="C:\\Program Files\\Hotone\\Ampero II\\Ampero II.exe"
MARKER='EffectChain Refresh'
REQUEST_LINE='请求命令地址'
TIMEOUT=45
STALL_GRACE=15

N=10
ARM_A=plain
ARM_B=plain
while getopts "n:" opt; do
    case "$opt" in
        n) N="$OPTARG" ;;
        *) echo "usage: $0 [-n COUNT_PER_ARM] [ARM_A] [ARM_B]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] && ARM_A="$1"
[ $# -ge 2 ] && ARM_B="$2"

LOAD_PIDS=()

arm_setup() {
    case "$1" in
        sniff) aseqdump -p 20:0 > /dev/null 2>&1 & echo $! ;;
        trace) export WINEDEBUG='+midi,+alsa'; echo "" ;;
        load)
            for _ in $(seq 1 "$(nproc)"); do
                yes > /dev/null 2>&1 & LOAD_PIDS+=("$!")
            done
            echo ""
            ;;
        nokwin) export WINE_USE_KWIN_HACKS=0; echo "" ;;
        plain) echo "" ;;
        *) echo "unknown arm '$1'" >&2; exit 1 ;;
    esac
}

arm_teardown() {
    local pid="$1" name="$2"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    if [ "$name" = trace ]; then unset WINEDEBUG; fi
    if [ "$name" = nokwin ]; then unset WINE_USE_KWIN_HACKS; fi
    if [ "$name" = load ]; then
        for p in "${LOAD_PIDS[@]}"; do kill "$p" 2>/dev/null; done
        LOAD_PIDS=()
    fi
}

run_one() {
    local log; log="$(mktemp -t handshake-trial-XXXXXX.log)"
    "$LOADER" "$APP" > "$log" 2>&1 &
    local pid=$!
    local last_count=0 quiet=0 result=fail
    for _ in $(seq 1 "$TIMEOUT"); do
        if grep -aq "$MARKER" "$log" 2>/dev/null; then result=ok; break; fi
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        local count; count="$(grep -ac "$REQUEST_LINE" "$log" 2>/dev/null || true)"
        : "${count:=0}"
        if [ "$count" -gt 0 ] && [ "$count" -eq "$last_count" ]; then
            quiet=$((quiet + 1))
            [ "$quiet" -ge "$STALL_GRACE" ] && break
        else
            quiet=0
        fi
        last_count="$count"
        sleep 1
    done
    kill "$pid" 2>/dev/null
    "${PROTON_DIR:-$DATA_DIR/proton}/bin/wineserver" -k 2>/dev/null
    rm -f "$log"
    sleep 2
    echo "$result"
}

declare -A pass total
pass[$ARM_A]=0; pass[$ARM_B]=0
total[$ARM_A]=0; total[$ARM_B]=0
sequence=""

for i in $(seq 1 "$N"); do
    for arm in "$ARM_A" "$ARM_B"; do
        setup_pid="$(arm_setup "$arm")"
        r="$(run_one)"
        arm_teardown "$setup_pid" "$arm"
        total[$arm]=$((total[$arm] + 1))
        if [ "$r" = ok ]; then
            pass[$arm]=$((pass[$arm] + 1))
            sequence+="#"
        else
            sequence+="."
        fi
        echo "[$arm] trial $((total[$arm]))/$N: $r    (running: $sequence)"
    done
done

echo
echo "=== Results (alternated, $N trials per arm) ==="
printf '%-10s %d/%d\n' "$ARM_A" "${pass[$ARM_A]}" "${total[$ARM_A]}"
if [ "$ARM_A" != "$ARM_B" ]; then
    printf '%-10s %d/%d\n' "$ARM_B" "${pass[$ARM_B]}" "${total[$ARM_B]}"
fi
echo
echo "Remember: a difference here is only meaningful if it survives being re-run -"
echo "this exact non-stationarity is why several earlier single-series theories"
echo "in docs/INVESTIGATION.md were each initially convincing and then withdrawn."
