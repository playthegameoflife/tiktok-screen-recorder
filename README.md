# TikTok Screen Recorder

Headless screen recording pipeline for TikTok videos. Records the actual video playback via X11 capture, producing a screen recording that's visually identical to watching the video — not a re-muxed file.

**Why screen record instead of direct download?** Platform compliance. The output is a genuine screen recording of mpv playing the video, with real-time audio capture from PulseAudio.

## Pipeline Overview

```
yt-dlp download (source.mp4)
         ↓
ffmpeg transcode (H.264 720x1280, KEEP audio)
         ↓
Xvfb :95 + mpv (holds at frame 0 until /tmp/start.flag)
         ↓
ffmpeg x11grab (720x1280 @ 30fps) ← video capture
         ↓
ffmpeg PulseAudio monitor ← audio capture
         ↓
mpv_ipc.py unpauses mpv via IPC socket
         ↓
wait for capture to finish
         ↓
ffmpeg mux (video + PCM → AAC)
         ↓
trim_1to1.py (align to exact source [0..duration])
         ↓
final.mp4 — frame-accurate, A/V synced
```

## Files

| File | Purpose |
|------|---------|
| `capture_mpv.sh` | Main recorder — Xvfb + mpv + x11grab + PulseAudio + IPC unpause |
| `capture_1to1.sh` | Chrome/SwiftShader variant (uses HTML player + Chrome instead of mpv) |
| `mpv_ipc.py` | Unpauses mpv via UNIX socket IPC when capture is ready |
| `trim_1to1.py` | Trims recording to exact source duration [0..src_dur] using frame matching |
| `fullscreen_player.html` | HTML5 video player served over localhost for Chrome variant |

## capture_mpv.sh Usage

```bash
# Prerequisites: ffmpeg, mpv, Xvfb, PulseAudio, python3
# Download source
yt-dlp --no-warnings -f "mp4" -o /tmp/src.mp4 "https://www.tiktok.com/@user/video/123"

# Transcode to H.264 720x1280 (KEEP audio)
ffmpeg -y -i /tmp/src.mp4 \
  -vf "scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2" \
  -c:v libx264 -preset fast -crf 23 -pix_fmt yuv420p \
  -c:a aac -b:a 128k \
  /tmp/play_src.mp4

# Get duration
DURATION=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 /tmp/play_src.mp4)

# Run capture
SOURCE=/tmp/play_src.mp4 OUT_FINAL=/tmp/recorded.mp4 \
  bash capture_mpv.sh "$DURATION"
```

**Key environment variables:**
- `SOURCE` — path to the transcoded source video (for trim alignment)
- `OUT_FINAL` — output MP4 path
- `DISPLAY_NUM` — X11 display number (default `:95`)
- `DURATION` — capture duration in seconds (from source video duration)

**Dependencies:**
```bash
apt install ffmpeg mpv Xvfb pulseaudio python3 numpy
```

## How Frame-Accurate Sync Works

1. **Hold at frame 0:** mpv is launched with `--pause --start=0` — it loads the video and holds exactly at the first frame
2. **Capture waits:** ffmpeg x11grab and PulseAudio monitor start capturing
3. **GO signal:** 1 second later, `mpv_ipc.py` sends `{ "command": ["set_property", "pause", false] }` via UNIX socket IPC
4. **Trim alignment:** The recording starts with ~1s of held frame 0. `trim_1to1.py` finds where the real content begins by comparing frames to source frame 0, then extracts exactly `[lead_offset, lead_offset+src_duration]` — guaranteeing frame 0 = source frame 0 and final frame = real ending

## The Black X Cursor Bug

**Symptom:** A white X cursor appears in the center of recorded videos.

**Cause:** Xvfb's default X11 cursor rendering. The X11 server draws a hardware cursor sprite at the mouse position. Even though `--hide-cursor` is passed to Chrome/mpv, the X server itself renders a cursor into the x11grab capture.

**Fix:** Add `-nocursor` to the Xvfb command:
```bash
Xvfb :95 -screen 0 720x1280x24 -nocursor
```

## A/V Sync

- Video: `ffmpeg -f x11grab` captures display frames at 30fps
- Audio: `ffmpeg -f pulse -i virtual_speaker.monitor` captures PulseAudio output in real-time
- Both start simultaneously when `/tmp/start.flag` is created
- Both end when the capture duration is reached
- The muxer combines them — since both were recorded from the same playback session starting at the same instant, A/V stays in sync throughout

## Chrome/SwiftShader Variant (capture_1to1.sh)

Uses Chrome with SwiftShader (software GPU) + HTML player instead of mpv. Useful when:
- mpv can't play the source format
- You need Chrome's HTML overlay capabilities

Launches Chrome in kiosk mode with `--use-angle=swiftshader --enable-unsafe-swiftshader --disable-gpu-compositing`. The same Xvfb `-nocursor` flag applies.
