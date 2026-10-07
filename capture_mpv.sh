#!/bin/bash
# capture_mpv.sh — Frame-accurate screen recording with true A/V sync
# mpv plays video+audio to X11, ffmpeg x11grab captures video, PulseAudio captures audio.
# All three sync on /tmp/start.flag so video frame 0 = audio frame 0.
#
# Args:
#   $1 = duration in seconds (source duration)
#   SOURCE = path to H.264 source file (required)
#   OUT_FINAL = output mp4 path (required)
#   DISPLAY_NUM = X11 display (default :95)
#
set -e

SOURCE="${SOURCE:?Must set SOURCE}"
OUT_FINAL="${OUT_FINAL:?Must set OUT_FINAL}"
DISPNUM="${DISPLAY_NUM:-:95}"
DURATION="${1:-10}"

SRC_DIR="$(dirname "$SOURCE")"
OUT_VID=/tmp/mpv_capture_raw.mp4
OUT_AUD=/tmp/mpv_capture_aud.wav
OUT_MUX=/tmp/mpv_capture_muxed.mp4

echo ">>> capture_mpv: ${DURATION}s -> $OUT_FINAL"

# Validate
if [ ! -f "$SOURCE" ]; then
    echo "ERROR: SOURCE not found: $SOURCE"
    exit 1
fi

ACTUAL_DUR=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$SOURCE" 2>/dev/null)
[ -z "$ACTUAL_DUR" ] && { echo "ERROR: cannot read source duration"; exit 1; }
echo "Source: $ACTUAL_DUR s"

# ── Kill previous sessions ──────────────────────────────────────────
pkill -9 Xvfb 2>/dev/null || true
pkill -9 mpv 2>/dev/null || true
pkill -9 pulseaudio 2>/dev/null || true
sleep 1
rm -f /tmp/.X${DISPNUM#:}*-lock /tmp/pulse-* /tmp/start.flag

# ── Xvfb ────────────────────────────────────────────────────────────
Xvfb $DISPNUM -screen 0 720x1280x24 -nocursor >/tmp/xvfb_mpv.log 2>&1 &
sleep 1
if ! pgrep -x Xvfb >/dev/null; then
    echo "ERROR: Xvfb failed"; cat /tmp/xvfb_mpv.log; exit 1; fi

# ── PulseAudio (virtual sink for audio capture) ─────────────────────
pulseaudio --exit-idle-time=-1 --daemonize=no \
    --load="module-null-sink sink_name=mpv_speaker sink_properties=device.description=mpv_speaker" \
    >/tmp/pulse_mpv.log 2>&1 &
sleep 1

# Set mpv sink so audio goes to our virtual speaker (not hardware)
pactl set-default-sink mpv_speaker 2>/dev/null || true

# ── mpv IPC (for unpause control) ──────────────────────────────────
MPV_SOCK=/tmp/mpv.sock
rm -f $MPV_SOCK

# ── mpv (hold at frame 0 until /tmp/start.flag) ───────────────────
# --pause --start=0: mpv holds at frame 0 internally, no HTML player needed
# This gives us a CLEAN frame 0 — no player chrome, no overlay
# Use --input-ipc-server so we can unpause via socket command
DISPLAY=$DISPNUM mpv "$SOURCE" \
    --no-cache \
    --pause \
    --start=0 \
    --vo=x11 \
    --fs \
    --no-border \
    --autofit=720x1280 \
    --hwdec=no \
    --keep-open=no \
    --input-ipc-server=$MPV_SOCK \
    >/tmp/mpv_cap.log 2>&1 &
MPV_PID=$!
echo "mpv PID=$MPV_PID (holding at frame 0, IPC: $MPV_SOCK)"

# Wait for mpv window to initialize
sleep 2

# ── Start video + audio capture in background ───────────────────────
# +5s margin: 1s lead-in buffer + 4s tail buffer for source < DURATION case
CAP_DUR=$(echo "$DURATION + 5" | bc)

# VIDEO: x11grab
DISPLAY=$DISPNUM ffmpeg -y \
    -f x11grab -video_size 720x1280 -framerate 30 -i $DISPNUM \
    -c:v libx264 -preset ultrafast -threads 1 -crf 20 -pix_fmt yuv420p \
    -t "$CAP_DUR" "$OUT_VID" >/tmp/vid_cap.log 2>&1 &
VPID=$!

# AUDIO: PulseAudio monitor of mpv_speaker
ffmpeg -y \
    -f pulse -i mpv_speaker.monitor \
    -c:a pcm_s16le -ar 48000 \
    -t "$CAP_DUR" "$OUT_AUD" >/tmp/aud_cap.log 2>&1 &
APID=$!

# Give capture a beat to stabilize, then unpause mpv from frame 0 via IPC
sleep 1
echo ">>> GO — unpausing mpv"
python3 "$(dirname "$0")/mpv_ipc.py"

# Wait for both streams to finish
wait $VPID; VRC=$?
wait $APID; ARC=$?
echo ">>> capture done: VID_RC=$VRC AUD_RC=$ARC"

# ── Cleanup players ────────────────────────────────────────────────
kill $MPV_PID 2>/dev/null || true
pkill -9 Xvfb 2>/dev/null || true
pkill -9 pulseaudio 2>/dev/null || true
rm -f /tmp/start.flag

# ── Check capture sanity ───────────────────────────────────────────
if [ ! -f "$OUT_VID" ] || [ ! -f "$OUT_AUD" ]; then
    echo "ERROR: capture files missing"; exit 1; fi

VID_DUR=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$OUT_VID" 2>/dev/null)
AUD_DUR=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$OUT_AUD" 2>/dev/null)
echo "Captured — VID: ${VID_DUR}s, AUD: ${AUD_DUR}s"

# ── Mux video + audio (no -shortest — trim step handles exact duration) ───
ffmpeg -y -i "$OUT_VID" -i "$OUT_AUD" \
    -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
    -c:a aac -b:a 128k \
    -map 0:v:0 -map 1:a:0 \
    -t "$CAP_DUR" \
    "$OUT_MUX" >/tmp/mux.log 2>&1
MUX_RC=$?
echo "Mux RC=$MUX_RC"

# ── Trim to exact source duration [0..ACTUAL_DUR] ─────────────────
# Always trim to guarantee exact frame count = source frame count (A/V sync guarantee).
# LEAD_HINT=0 because --pause --start=0 means mpv starts cleanly with no player chrome.
LEAD_HINT=0.0 python3 "$(dirname "$0")/trim_1to1.py" "$OUT_MUX" "$SOURCE" "$OUT_FINAL" "$LEAD_HINT"

echo "=== Results ==="
ffprobe -v error -show_entries stream=codec_type,codec_name \
    -of default=noprint_wrappers=1 "$OUT_FINAL"
FINAL_DUR=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$OUT_FINAL" 2>/dev/null)
echo "Final duration: ${FINAL_DUR}s"
echo "Done: $OUT_FINAL"