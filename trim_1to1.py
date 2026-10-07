#!/usr/bin/env python3
"""Trim a screen recording to EXACTLY the source video's content window [0..src_dur].

The recorder captures the held first frame while ffmpeg spins up, so the real
playback begins ~1s into the recording (a lead-in). That lead shifts the timeline
and, if the capture was only src_dur long, truncates the ending. This script:
  1. Finds where the recording's first real frame appears (best match to source frame 0)
     -> the exact lead-in offset.
  2. Extracts from that offset for exactly src_dur seconds -> frame 0 at the start
     AND the true finale at the end, 1:1 with the source.

Usage: python3 trim_1to1.py <recording.mp4> <source.mp4> <output.mp4> [lead_hint]
  lead_hint (optional, default 1.0): search the lead in [max(0,lead_hint-1.5), lead_hint+1.5].
Requires: ffmpeg, ffprobe, numpy.
"""
import subprocess, sys, os
import numpy as np

def ffprobe_dur(p):
    # FFmpeg 7.x fix: use -of csv=p=0 for clean numeric output (no key prefix).
    # The chained "1=nokey=1" form fails on FFmpeg 7.x with
    # "Unable to parse option value '1=nokey=1' as boolean".
    r = subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
        "-of","csv=p=0",p],capture_output=True,text=True)
    try: return float(r.stdout.strip())
    except: return 0.0

def grab(v,t):
    r = subprocess.run(["ffmpeg","-v","error","-ss",str(t),"-i",v,"-frames:v","1",
        "-vf","scale=88:156","-f","rawvideo","-pix_fmt","gray","pipe:1"],capture_output=True)
    if not r.stdout: return None
    return np.frombuffer(r.stdout,dtype=np.uint8).astype(float)

def find_lead(rec, src, hint):
    s0 = grab(src, 0.0)
    if s0 is None: return hint
    lo, hi = max(0.0, hint-1.5), hint+1.5
    best = (1e9, hint)
    t = lo
    while t <= hi:
        f = grab(rec, t)
        if f is not None and len(f)==len(s0):
            d = float(np.abs(f-s0).mean())
            if d < best[0]: best = (d, t)
        t += 0.2
    return best[1]

def main():
    if len(sys.argv) < 4:
        print(__doc__); return 2
    rec, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
    lead_hint = float(sys.argv[4]) if len(sys.argv)>4 and sys.argv[4] else 1.0
    sdur = ffprobe_dur(src)
    lead = find_lead(rec, src, lead_hint)
    print(f"src_dur={sdur:.2f}s  detected lead={lead:.2f}s")
    if lead > sdur:
        print("lead exceeds source; using 0.0"); lead=0.0
    # Extract [lead, lead+sdur] — guarantees start=frame0 and end=realfinale.
    # Trim BEFORE AudioVideo to keep exact length; re-encode cleanly.
    r = subprocess.run(["ffmpeg","-hide_banner","-y","-ss",f"{lead:.2f}","-i",rec,
        "-t",f"{sdur:.2f}","-c:v","libx264","-preset","veryfast","-crf","20","-pix_fmt","yuv420p",
        "-c:a","aac","-b:a","160k",out],capture_output=True,text=True)
    if r.returncode!=0:
        print("trim failed:", r.stderr[-500:]); return 1
    odur = ffprobe_dur(out)
    print(f"output dur={odur:.2f}s (target {sdur:.2f}s)")
    print(f"aligned: start=src[0], end=src[{sdur:.2f}]")
    return 0

if __name__=="__main__":
    sys.exit(main())