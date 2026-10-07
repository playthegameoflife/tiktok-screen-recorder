#!/usr/bin/env bash
# PROVEN 1:1 screen recording (video + audio) on a 2-CPU box. 2026-09-11.
# Achieves ~98% real-motion frames over a FULL-length clip WITH audio, by decoupling
# the live capture encode (near-zero CPU) from the quality re-encode (offline).
#
# Usage:
#   Prepare /tmp/play_src.mp4 (H.264 video, any duration) + /tmp/fullscreen_player.html
#     src must be MUXED video+audio. Also set SOURCE=/path/to/original.mp4 (the aligned ref for trim).
#   OUT_FINAL=/path/out.mp4 SOURCE=/path/src.mp4 bash scripts/capture_1to1.sh <duration_seconds>
#   The script records <duration> + margin, then TRIMS to exactly [0..<duration>] using the SOURCE,
#   so the output starts on the original's first frame and ends on its last — true 1:1 scenes.
#
# Pipeline:
#   1. Xvfb + pulse null-sink + Chrome (SwiftShader, --disable-gpu-compositing, --hide-cursor)
#   2. VIDEO captured with -preset ultrafast -threads 1 (min CPU)  -> vid_lean.mp4
#      AUDIO recorded in parallel to PCM WAV (min CPU)              -> aud.wav
#   3. Offline: re-encode video to veryfast/crf20 + mux PCM->AAC together -> final.mp4
set -u
DISPNUM="${DISPLAY_NUM:-:95}"   # override with DISPLAY_NUM env var, e.g. DISPLAY_NUM=":97" for display :97
DUR="${1:-62}"
OUT_VID=/tmp/cap_vid_lean.mp4
OUT_AUD=/tmp/cap_aud.wav
OUT_FINAL="${OUT_FINAL:-/tmp/cap_final_1to1.mp4}"
export DISPLAY=$DISPNUM

echo ">>> capture_1to1: ${DUR}s -> $OUT_FINAL"
pkill -9 -x Xvfb 2>/dev/null; pkill -9 -x chrome 2>/dev/null; pkill -9 -x pulseaudio 2>/dev/null; sleep 3
rm -f /tmp/.X${DISPNUM#:}-lock /tmp/.X11-unix/X${DISPNUM#:} /tmp/pulse-* 2>/dev/null

Xvfb $DISPNUM -screen 0 720x1280x24 -nocursor >/tmp/xvfb.log 2>&1 & sleep 3
pulseaudio --exit-idle-time=-1 --daemonize=yes --system=false \
  --load="module-null-sink sink_name=virtual_speaker sink_properties=device.description=Virtual_Speaker" >/tmp/pulse.log 2>&1
sleep 2
for i in $(seq 1 10); do
  pactl info >/dev/null 2>&1 && pactl list short sources 2>/dev/null | grep -q virtual_speaker.monitor && break
  pulseaudio --exit-idle-time=-1 --daemonize=yes --system=false \
    --load="module-null-sink sink_name=virtual_speaker sink_properties=device.description=Virtual_Speaker" >/tmp/pulse.log 2>&1
  sleep 2
done
pactl set-default-sink virtual_speaker

fuser -k 8899/tcp 2>/dev/null; (cd /tmp && python3 -m http.server 8899 >/tmp/http.log 2>&1) & sleep 1

# --disable-gpu-compositing is THE 1:1 fix. --hide-cursor hides the pointer sprite.
# --disable-features=ChromeTranslateUi removes the translate widget (can appear as X in center).
google-chrome --no-sandbox --disable-setuid-sandbox --window-size=720,1280 --hide-cursor \
  --use-angle=swiftshader --enable-unsafe-swiftshader --disable-gpu-compositing --disable-composited-antialiasing \
  --autoplay-policy=no-user-gesture-required --disable-dev-shm-usage --no-first-run \
  --kiosk --disable-features=ChromeTranslateUi,CursorOverlay,WebAuthenticationProxy \
  "http://localhost:8899/fullscreen_player.html" >/tmp/chrome.log 2>&1 &
sleep 12
command -v xdotool >/dev/null 2>&1 && DISPLAY=$DISPNUM xdotool mousemove 50000 50000 2>/dev/null || true
# Clear any stale start flag, then let the recorder get ready. The player holds at scene 0
# until /tmp/start.flag appears — created right after ffmpeg begins, so recording starts
# from the video's FIRST frame (no more mid-clip start / wrong end scene).
rm -f /tmp/start.flag

# VIDEO (lean, near-zero CPU to keep SwiftShader unstarved)
# Record DUR+4 margin (lead-in ~1s + tail buffer) so trimming to [0..DUR] keeps the real ending.
CAP_DUR=$((DUR+4))
timeout $((CAP_DUR+20)) ffmpeg -hide_banner -y -f x11grab -video_size 720x1280 -framerate 30 -i $DISPNUM \
  -c:v libx264 -preset ultrafast -threads 1 -crf 23 -pix_fmt yuv420p -t "$CAP_DUR" "$OUT_VID" >/tmp/vid_lean.log 2>&1 &
VPID=$!
# AUDIO (parallel, PCM = near-zero CPU)
timeout $((CAP_DUR+20)) ffmpeg -hide_banner -y -f pulse -i virtual_speaker.monitor -c:a pcm_s16le -ar 48000 -t "$CAP_DUR" "$OUT_AUD" >/tmp/aud_lean.log 2>&1 &
APID=$!
# Give ffmpeg a beat to start capturing, then tell the player to begin from scene 0.
# Record with +3s margin so the held-frame lead-in (≈1s) doesn't truncate the ending.
sleep 1
touch /tmp/start.flag
wait $VPID; VRC=$?
wait $APID; ARC=$?
pkill -9 -x chrome 2>/dev/null; pkill -9 -x Xvfb 2>/dev/null
rm -f /tmp/start.flag
echo "VID_RC=$VRC AUD_RC=$ARC"

# OFFLINE: mux lean video + PCM audio first, THEN trim to the exact source window
# [0..DUR] so the output's first frame = source frame 0 and final frame = real ending.
ffmpeg -hide_banner -y -i "$OUT_VID" -i "$OUT_AUD" -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
  -c:a aac -b:a 160k -shortest /tmp/cap_muxed.mp4 >/tmp/mux_re.log 2>&1
MUX_RC=$?
echo "MUX_RC=$MUX_RC"
if [ -n "${SOURCE:-}" ] && [ -f "$SOURCE" ]; then
    LEAD_HINT="${LEAD_HINT:-1.0}"
    python3 "$(dirname "$0")/trim_1to1.py" /tmp/cap_muxed.mp4 "$SOURCE" "$OUT_FINAL" "$LEAD_HINT"
else
    echo "WARN: no SOURCE set — skipping exact trim; using muxed output"
    cp /tmp/cap_muxed.mp4 "$OUT_FINAL"
fi

echo "=== video smoothness (want ~98%) ==="
TOTAL=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=noprint_wrappers=1 "$OUT_VID")
UNIQ=$(ffmpeg -hide_banner -i "$OUT_VID" -vf mpdecimate -f null - 2>&1 | grep -oE "frame=[ ]*[0-9]+" | tail -1)
echo "TOTAL=$TOTAL UNIQ=$UNIQ"
echo "=== final ==="
ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$OUT_FINAL"
ffmpeg -hide_banner -i "$OUT_FINAL" -af volumedetect -f null - 2>&1 | grep -E "max_volume" | head -1