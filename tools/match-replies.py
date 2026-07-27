#!/usr/bin/env python3
"""
Decode Ampero II SysEx handshake traffic and tell you, for a given stalled
address, whether the pedal answered on the wire and whether Wine's
alsamidi.drv actually received/assembled that reply correctly.

Framing (indexed from just after the 5-byte "F0 21 25 4D 50" header):
    idx 3    0x11 = request from host, 0x12 = reply from pedal
    idx 6-7  chunk offset, 00 00 on the first chunk of a reply
    idx 9-15 28-bit address, one nibble per byte, little-endian

Usage:
    # Was the pedal silent, or did it answer and something else lost it?
    match-replies.py --wire wire_capture.log --address 1080000

    # Also check whether Wine's driver received/assembled it correctly.
    # (Requires alsamidi.c's trace_sysex_chunk() to have wall-clock
    # timestamps - see STATUS.md Bug #5, commit 7619394c.)
    match-replies.py --wire wire_capture.log --wine-trace /tmp/wine_midi_trace_proton.log \\
        --address 1080000 [--window T0 T1]

Capture the wire with, e.g.:
    aseqdump -p 20:0 | while IFS= read -r line; do
        printf '%s %s\\n' "$(date +%s.%3N)" "$line"
    done > wire_capture.log
(port number varies - find it with `aconnect -l`, look for the pedal's MIDI client)
"""
import argparse
import re
import sys


def addr_of(msg):
    if len(msg) < 21 or msg[0] != 0xF0:
        return None, None
    kind = msg[8]
    nibbles = msg[14:21]
    if len(nibbles) < 7:
        return kind, None
    addr = sum(n << (4 * i) for i, n in enumerate(nibbles))
    return kind, addr


def parse_wire(path, t0, t1):
    """Parses lines of the form '<epoch> <port>  System exclusive  XX XX ...'
    (i.e. aseqdump's raw-view output, one wall-clock timestamp prefixed per
    line - see the module docstring for how to produce this)."""
    msgs = []
    cur = None
    cur_ts = None
    with open(path) as f:
        for line in f:
            m = re.match(r'^(\d+\.\d+)\s+.*System exclusive\s+([0-9A-Fa-f ]+)$', line.strip())
            if not m:
                continue
            ts = float(m.group(1))
            if t0 is not None and (ts < t0 - 1 or ts > t1 + 1):
                continue
            byts = [int(x, 16) for x in m.group(2).split()]
            if byts and byts[0] == 0xF0:
                if cur is not None:
                    msgs.append((cur_ts, cur))
                cur, cur_ts = byts, ts
            elif cur is not None:
                cur.extend(byts)
            if cur is not None and cur[-1] == 0xF7:
                msgs.append((cur_ts, cur))
                cur = None
    if cur is not None:
        msgs.append((cur_ts, cur + ['INCOMPLETE']))
    return msgs


def parse_wine_trace(path, t0, t1):
    """Parses '[epoch.usec][dev N] chunk len=... hdr_bytes_recorded=...
    expect_start=B: XX XX ...' lines from trace_sysex_chunk()'s log file.

    Each logged chunk is one ALSA-delivered event, the same granularity the
    wire capture sees - messages are reconstructed the same way (concatenate
    from 0xF0 to 0xF7), per source device index. hdr_bytes_recorded and
    expect_start are MIDIHDR buffer bookkeeping, NOT message-boundary
    markers: a single reply routinely spans several small app-side buffers,
    so those fields must not be used to decide where one wire-level chunk
    ends and the next begins."""
    msgs = []
    cur, cur_ts = {}, {}
    pat = re.compile(r'^\[(\d+\.\d+)\]\[dev (\d+)\] chunk len=(\d+) '
                      r'hdr_bytes_recorded=(\d+) expect_start=(\d+):(.*)$')
    with open(path) as f:
        for line in f:
            m = pat.match(line.strip())
            if not m:
                continue
            ts = float(m.group(1))
            if t0 is not None and (ts < t0 - 1 or ts > t1 + 1):
                continue
            dev = int(m.group(2))
            data = [int(x, 16) for x in m.group(6).split()]
            if data and data[0] == 0xF0:
                if dev in cur:
                    msgs.append((cur_ts[dev], cur[dev]))
                cur[dev], cur_ts[dev] = list(data), ts
            elif dev in cur:
                cur[dev].extend(data)
            if dev in cur and cur[dev] and cur[dev][-1] == 0xF7:
                msgs.append((cur_ts[dev], cur[dev]))
                del cur[dev], cur_ts[dev]
    for dev, data in cur.items():
        msgs.append((cur_ts[dev], data + ['INCOMPLETE']))
    return msgs


def describe(msgs, target):
    for ts, msg in msgs:
        incomplete = bool(msg) and msg[-1] == 'INCOMPLETE'
        clean = [b for b in msg if isinstance(b, int)]
        kind, addr = addr_of(clean)
        tag = {0x11: "REQ  ", 0x12: "REPLY"}.get(kind, "?    ")
        addr_s = f"{addr:#x}" if addr is not None else "?"
        hit = "  <=== TARGET" if addr == target else ""
        print(f"  t={ts:.3f} {tag} addr={addr_s:<10} len={len(clean):<4} "
              f"complete={not incomplete}{hit}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--wire', required=True, help='timestamped aseqdump capture')
    ap.add_argument('--wine-trace', help='/tmp/wine_midi_trace_proton.log (optional)')
    ap.add_argument('--address', required=True, help='stalled address, hex, no 0x prefix (e.g. 1080000)')
    ap.add_argument('--window', nargs=2, type=float, metavar=('T0', 'T1'),
                     help='restrict to this epoch-seconds window (default: whole file)')
    args = ap.parse_args()

    target = int(args.address, 16)
    t0, t1 = (args.window if args.window else (None, None))

    wire = parse_wire(args.wire, t0, t1)
    print(f"=== WIRE capture: {len(wire)} messages ===")
    describe(wire, target)
    wire_hit = [m for m in wire if addr_of([b for b in m[1] if isinstance(b, int)])[1] == target]

    trace_hit = None
    if args.wine_trace:
        trace = parse_wine_trace(args.wine_trace, t0, t1)
        print(f"\n=== WINE TRACE: {len(trace)} messages ===")
        describe(trace, target)
        trace_hit = [m for m in trace if addr_of([b for b in m[1] if isinstance(b, int)])[1] == target]

    print(f"\n=== VERDICT for address {target:#x} ===")
    if not wire_hit:
        print("NOT on the wire at all -> the pedal itself never sent this reply.")
    else:
        print(f"On the wire: YES ({len(wire_hit)} matching frame(s), "
              f"complete={all(m[1][-1] == 0xF7 for m in wire_hit)}).")
        if args.wine_trace:
            if not trace_hit:
                print("NOT in Wine's trace -> the reply reached the machine but Wine's "
                      "alsamidi driver (or something below it) lost it. Look at "
                      "handle_sysex_event() in alsamidi.c.")
            else:
                same = wire_hit[0][1] == trace_hit[0][1]
                print(f"In Wine's trace: YES ({len(trace_hit)} matching frame(s)), "
                      f"byte-identical to the wire: {same}.")
                if same:
                    print("-> Wine delivered this reply to the app correctly and completely. "
                          "The drop is on the app side, not ours.")
                else:
                    print("-> Wine received something for this address but it does NOT match "
                          "the wire byte-for-byte - a real Wine-side bug. Diff the two printouts above.")


if __name__ == '__main__':
    main()
