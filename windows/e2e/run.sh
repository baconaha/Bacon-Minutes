#!/usr/bin/env bash
# End-to-end run of the real Electron app on Linux (needs Xvfb, ffmpeg, python3 and a
# globally installed `playwright` package). Generates a 95-minute sample video with a
# 1263-cue SRT, starts a mock OpenAI-compatible server, then drives the app.
set -euo pipefail
cd "$(dirname "$0")"
WORK=.work
mkdir -p "$WORK/media" "$WORK/shots"

if [ ! -f "$WORK/media/1793756624935_周会复盘_FeishuMinutes.mp4" ]; then
  python3 gen_srt.py "$WORK/media/周会复盘_FeishuMinutes.srt" 5683 1263
  python3 gen_srt.py "$WORK/media/访谈录音.srt" 170 40
  ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=320x180:rate=5" -f lavfi -i "sine=frequency=330:sample_rate=22050" \
    -t 5683 -c:v libx264 -preset ultrafast -crf 38 -pix_fmt yuv420p -c:a aac -b:a 24k -movflags +faststart \
    "$WORK/media/1793756624935_周会复盘_FeishuMinutes.mp4"
  ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:sample_rate=22050" -t 180 -c:a aac -b:a 32k "$WORK/media/访谈录音.m4a"
fi

(cd .. && npm run build)

node mock-llm.cjs > "$WORK/mock.log" 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
sleep 1

# Electron refuses to start as root without --no-sandbox; the scripts pass it.
run() { xvfb-run -a -s "-screen 0 1280x820x24" node "$1" 2>&1 | grep -E "^(PASS|FAIL|rows|toast|detail|import took|errors|console errors|FAILED)" || true; }
run smoke.cjs
run interact.cjs
run stage3.cjs
THEME=dark run stage3.cjs
echo "screenshots in $(pwd)/$WORK/shots"
