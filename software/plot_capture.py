#!/usr/bin/env python3
"""
plot_capture_8ch.py — AD4857 AE Event Visualiser (8-channel, 4x2 grid)
========================================================================
Same binary format / header layout as plot_capture.py, but plots all
8 channels of one event on a single figure, arranged 4 rows x 2 columns
(ch0..ch7, row-major: [ch0,ch1] / [ch2,ch3] / [ch4,ch5] / [ch6,ch7]).

Expected filenames (default naming, override with --pattern):
 ch0_event_000.bin, ch1_event_000.bin, ... ch7_event_000.bin

Usage examples:
  # Auto-build filenames ch0..ch7 for event 000 in current directory
  python3 plot_capture_8ch.py --event 000

  # Files live in a different folder
  python3 plot_capture_8ch.py --event 000 --dir ./captures

  # Custom filename pattern ({ch} and {event} placeholders)
  python3 plot_capture_8ch.py --event 12 --pattern "AE_ch{ch}_evt{event}.bin"

  # Explicit list of 8 files, in ch0..ch7 order
  python3 plot_capture_8ch.py --files ch0_event_000.bin ch1_event_000.bin \
      ch2_event_000.bin ch3_event_000.bin ch4_event_000.bin ch5_event_000.bin \
      ch6_event_000.bin ch7_event_000.bin

Options mirror plot_capture.py (samples/pretrig/threshold/pdt/hdt/hlt are
applied to every channel unless overridden per-channel in the header).
"""

import sys
import os
import argparse
import struct

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


# ── Constants ───────────────────────────────────────────────────────────────
MAGIC = 0xAE5EE5AE
HDL_HEADER_WORDS = 32  # 16-bit words
HDL_HEADER_BYTES = HDL_HEADER_WORDS * 2  # 64 bytes

# AD4857 softspan M2.5-2.5: signed 16-bit, +-2.5 V full-scale.
LSB_TO_MV = 2500.0 / 32768.0  # mV per ADC code

NUM_CHANNELS = 8
GRID_ROWS, GRID_COLS = 4, 2  # 4 rows x 2 columns


# ── Argument parsing ─────────────────────────────────────────────────────────
def parse_args():
    p = argparse.ArgumentParser(
        description="AD4857 AE 8-channel event capture visualiser (4x2 grid)"
    )
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument(
        "--event",
        type=str,
        help="Event id, e.g. 000 (used with --dir/--pattern to build ch0..ch7 filenames)",
    )
    src.add_argument(
        "--files",
        nargs=8,
        metavar="CHFILE",
        help="Explicit list of 8 files in ch0..ch7 order",
    )

    p.add_argument(
        "--dir",
        type=str,
        default=".",
        help="Directory containing capture files (used with --event)",
    )
    p.add_argument(
        "--pattern",
        type=str,
        default="ch{ch}_event_{event}.bin",
        help="Filename pattern with {ch} and {event} placeholders",
    )

    p.add_argument("--samples", type=int, default=0, help="Waveform depth override")
    p.add_argument("--pretrig", type=int, default=512, help="Pre-trigger samples")
    p.add_argument(
        "--threshold", type=float, default=0.0, help="Threshold in mV (0=auto)"
    )
    p.add_argument("--pdt", type=int, default=0, help="PDT in samples (0=read from header)")
    p.add_argument("--hdt", type=int, default=0, help="HDT in samples (0=read from header)")
    p.add_argument("--hlt", type=int, default=0, help="HLT in samples (0=read from header)")
    p.add_argument("--out", type=str, default="adc_plot_8ch.png", help="Output PNG")
    p.add_argument("--no-show", action="store_true", help="Skip interactive window")
    return p.parse_args()


# ── Header parsing ────────────────────────────────────────────────────────────
def parse_header(raw_bytes):
    words = struct.unpack_from("<16I", raw_bytes, 0)  # 16 x uint32 LE
    magic = words[0]
    event_id = words[1]
    thresh_lsb = words[3]
    pdt = words[5]
    hdt = words[6]
    hlt = words[7]
    wf_len = words[9] if words[9] else 16384
    peak_lsb = words[11]
    energy_lo = words[12]
    energy_hi = words[13]
    duration = words[14]
    rise_time = words[15]

    energy = ((energy_hi >> 16) << 32) | energy_lo
    ae_count = energy_hi & 0xFFFF

    return dict(
        magic=magic,
        event_id=event_id,
        thresh_lsb=thresh_lsb,
        pdt=pdt,
        hdt=hdt,
        hlt=hlt,
        wf_len=wf_len,
        peak_lsb=peak_lsb,
        energy=energy,
        ae_count=ae_count,
        duration=duration,
        rise_time=rise_time,
    )


# ── Per-channel data loading ─────────────────────────────────────────────────
def load_channel(binfile, args):
    """Read + parse one channel's capture file. Returns a dict of everything
    needed to plot it, or None (with a printed warning) if the file is bad."""
    if not os.path.isfile(binfile):
        print(f"WARNING: file not found, skipping: {binfile}")
        return None

    raw = open(binfile, "rb").read()
    if len(raw) < HDL_HEADER_BYTES + 2:
        print(f"WARNING: file too small ({len(raw)} bytes), skipping: {binfile}")
        return None

    hdr = parse_header(raw)

    offset = 0
    if hdr["magic"] != MAGIC:
        for i in range(0, min(64, len(raw) - HDL_HEADER_BYTES), 4):
            if struct.unpack_from("<I", raw, i)[0] == MAGIC:
                offset = i
                hdr = parse_header(raw[i:])
                break
        else:
            print(
                f"WARNING: magic word not found in {binfile} — "
                "header fields may be invalid"
            )

    num_samples = args.samples if args.samples > 0 else hdr["wf_len"]
    if num_samples <= 0:
        num_samples = 16384

    wf_start = offset + HDL_HEADER_BYTES
    wf_bytes = num_samples * 2
    if len(raw) < wf_start + wf_bytes:
        available = (len(raw) - wf_start) // 2
        print(
            f"WARNING: {binfile}: only {available} samples available, "
            f"expected {num_samples}"
        )
        num_samples = available

    raw_samples = np.frombuffer(
        raw, dtype="<i2", count=num_samples, offset=wf_start
    )
    data_mv = raw_samples.astype(float) * LSB_TO_MV

    PRE = args.pretrig
    PDT = args.pdt if args.pdt > 0 else (hdr["pdt"] if hdr["pdt"] > 0 else 128)
    HDT = args.hdt if args.hdt > 0 else (hdr["hdt"] if hdr["hdt"] > 0 else 256)
    HLT = args.hlt if args.hlt > 0 else (hdr["hlt"] if hdr["hlt"] > 0 else 500)

    if args.threshold > 0.0:
        thresh_mv = args.threshold
    elif hdr.get("thresh_lsb", 0) > 0:
        thresh_mv = hdr["thresh_lsb"] * LSB_TO_MV
    else:
        peak_mv_hw = hdr["peak_lsb"] * LSB_TO_MV
        thresh_mv = peak_mv_hw * 0.15 if peak_mv_hw > 10.0 else 76.3

    hw_peak_mv = hdr["peak_lsb"] * LSB_TO_MV
    hw_duration = hdr["duration"]
    hw_ae_count = hdr["ae_count"]
    hw_energy = hdr["energy"]
    hw_rise = hdr["rise_time"]

    x = np.arange(num_samples) - PRE

    peak_idx = int(np.argmax(np.abs(data_mv))) if num_samples else 0
    peak_val = data_mv[peak_idx] if num_samples else 0.0

    pdt_end_idx = min(PRE + PDT, max(num_samples - 1, 0))
    pdt_region = data_mv[PRE:pdt_end_idx]
    if len(pdt_region):
        pdt_peak_rel = int(np.argmax(np.abs(pdt_region)))
        pdt_peak_idx = PRE + pdt_peak_rel
        pdt_peak_val = data_mv[pdt_peak_idx]
    else:
        pdt_peak_idx = PRE
        pdt_peak_val = 0.0

    max_buf_cap = 16384 - PRE
    ended_by_hdt = (hw_duration > 0) and (hw_duration < max_buf_cap)

    if ended_by_hdt:
        hdt_end_idx = min(PRE + hw_duration, num_samples - 1)
        hdt_start = max(PRE, hdt_end_idx - HDT)
        hdt_visible = True
    else:
        hdt_visible = False
        hdt_start = None
        hdt_end_idx = None

    hlt_end_idx = None
    if hw_duration > 0 and HLT > 0:
        event_end_idx = min(PRE + hw_duration, num_samples - 1)
        hlt_end_idx = min(event_end_idx + HLT, num_samples - 1)

    return dict(
        binfile=binfile,
        hdr=hdr,
        x=x,
        data_mv=data_mv,
        num_samples=num_samples,
        PRE=PRE,
        PDT=PDT,
        HDT=HDT,
        HLT=HLT,
        thresh_mv=thresh_mv,
        hw_peak_mv=hw_peak_mv,
        hw_duration=hw_duration,
        ended_by_hdt=ended_by_hdt,
        hw_ae_count=hw_ae_count,
        hw_energy=hw_energy,
        hw_rise=hw_rise,
        peak_idx=peak_idx,
        peak_val=peak_val,
        pdt_end_idx=pdt_end_idx,
        pdt_peak_idx=pdt_peak_idx,
        pdt_peak_val=pdt_peak_val,
        hdt_visible=hdt_visible,
        hdt_start=hdt_start,
        hdt_end_idx=hdt_end_idx,
        hlt_end_idx=hlt_end_idx,
    )


# ── Per-channel plotting (compact, sized for an 8-up grid) ──────────────────
def plot_channel(ax, ch_num, d):
    if d is None:
        ax.text(
            0.5,
            0.5,
            f"CH{ch_num}\n(no data / file missing)",
            ha="center",
            va="center",
            fontsize=10,
            color="grey",
            transform=ax.transAxes,
        )
        ax.set_xticks([])
        ax.set_yticks([])
        return

    x, data_mv, PRE = d["x"], d["data_mv"], d["PRE"]

    def rel(idx):
        return idx - PRE

    ax.plot(x, data_mv, color="#1f77b4", linewidth=0.6, drawstyle="steps-mid")

    thresh_mv = d["thresh_mv"]
    ax.axhline(thresh_mv, color="purple", linestyle=":", linewidth=1.0, alpha=0.8)
    ax.axhline(-thresh_mv, color="purple", linestyle=":", linewidth=1.0, alpha=0.8)

    ylim = ax.get_ylim()
    span = ylim[1] - ylim[0]

    # Pre-trigger + T0
    ax.axvspan(-PRE, 0, color="lightgrey", alpha=0.35)
    ax.axvline(0, color="red", linestyle="--", linewidth=1.2)

    # PDT window + peak marker
    ax.axvspan(0, rel(d["pdt_end_idx"]), color="gold", alpha=0.22)
    ax.axvline(
        rel(d["pdt_end_idx"]), color="goldenrod", linestyle="--", linewidth=0.9
    )
    ax.plot(
        rel(d["pdt_peak_idx"]),
        d["pdt_peak_val"],
        "*",
        color="goldenrod",
        markersize=8,
        zorder=5,
    )

    # HDT window — ONLY shown when event actually ended by HDT silence timeout
    if d["hdt_visible"] and d["hdt_start"] is not None and d["hdt_end_idx"] is not None:
        ax.axvspan(
            rel(d["hdt_start"]),
            rel(d["hdt_end_idx"]),
            color="green",
            alpha=0.18,
        )
        ax.axvline(
            rel(d["hdt_start"]), color="green", linestyle="--", linewidth=0.9
        )
        ax.axvline(
            rel(d["hdt_end_idx"]), color="darkgreen", linestyle="-", linewidth=1.1
        )

    # HLT window
    if d["hlt_end_idx"] is not None:
        event_end_rel = rel(min(PRE + d["hw_duration"], d["num_samples"] - 1))
        ax.axvspan(
            event_end_rel,
            rel(d["hlt_end_idx"]),
            color="orange",
            alpha=0.18,
        )
        ax.axvline(
            rel(d["hlt_end_idx"]),
            color="darkorange",
            linestyle="-",
            linewidth=1.1,
        )

    # Peak marker
    ax.plot(rel(d["peak_idx"]), d["peak_val"], "o", color="black", markersize=4, zorder=6)

    # Compact info box
    hdr = d["hdr"]
    end_reason = "HDT End" if d["ended_by_hdt"] else "MAX CAP (Sine/Long)"
    info = (
        f"EvtID {hdr['event_id']} | Pk {d['hw_peak_mv']:.0f}mV | AE {d['hw_ae_count']}\n"
        f"Dur {d['hw_duration']} sa ({end_reason}) | Rise {d['hw_rise']}"
    )
    ax.text(
        0.01,
        0.97,
        info,
        transform=ax.transAxes,
        fontsize=6.8,
        verticalalignment="top",
        bbox=dict(boxstyle="round,pad=0.2", fc="white", ec="grey", alpha=0.85),
    )

    ax.set_title(f"CH{ch_num} ({os.path.basename(d['binfile'])})", fontsize=9)
    ax.grid(True, linestyle=":", alpha=0.4)
    ax.tick_params(labelsize=7)


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    args = parse_args()

    if args.files:
        filepaths = list(args.files)
    else:
        filepaths = [
            os.path.join(args.dir, args.pattern.format(ch=ch, event=args.event))
            for ch in range(NUM_CHANNELS)
        ]

    channel_data = []
    for ch, fp in enumerate(filepaths):
        d = load_channel(fp, args)
        channel_data.append(d)
        if d is not None:
            hdr = d["hdr"]
            print(
                f"CH{ch}: {fp} EvtID={hdr['event_id']} Peak={d['hw_peak_mv']:.1f}mV "
                f"Dur={d['hw_duration']} AE={d['hw_ae_count']} Rise={d['hw_rise']}"
            )

    fig, axes = plt.subplots(
        GRID_ROWS, GRID_COLS, figsize=(16, 18), sharex=False
    )
    axes_flat = axes.flatten()  # row-major: [0,1],[2,3],[4,5],[6,7]

    for ch in range(NUM_CHANNELS):
        plot_channel(axes_flat[ch], ch, channel_data[ch])

    # Shared axis labels
    fig.text(
        0.5,
        0.005,
        "Sample index relative to trigger T0",
        ha="center",
        fontsize=11,
    )
    fig.text(
        0.005,
        0.5,
        "ADC value (mV)",
        va="center",
        rotation="vertical",
        fontsize=11,
    )

    event_label = args.event if args.event else "custom"
    fig.suptitle(
        f"AD4857 AE 8-Channel Event Capture — Event {event_label}",
        fontsize=14,
        y=0.995,
    )

    plt.tight_layout(rect=[0.015, 0.015, 1, 0.98])
    plt.savefig(args.out, dpi=200, bbox_inches="tight")
    print(f"\nSaved -> {args.out}")

    if not args.no_show:
        try:
            plt.switch_backend("TkAgg")
        except Exception:
            pass
        plt.show()


if __name__ == "__main__":
    main()