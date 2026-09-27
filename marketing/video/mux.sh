#!/bin/bash
# Adds the music to a silent master and writes the two deliverables.
#
#   ./mux.sh herdr        out/flux-herdr.mp4 and out/flux-herdr-github.mp4
#   ./mux.sh tailscale    out/flux-tailscale.mp4 and out/flux-tailscale-github.mp4
#   FADE_OUT=4 ./mux.sh herdr
#
# The music starts at videos.<name>.track_start_s in audio/music.json, fades
# in over FADE_IN seconds, and fades out over FADE_OUT seconds with an
# equal-power curve that ends on the last video frame. The GitHub copy is
# 1280x720 and stays under 10 MB.

set -eo pipefail
cd "$(dirname "$(readlink -f "$0")")"

NAME=${1:?give herdr or tailscale}
SILENT=${SILENT:-out/$NAME-master-silent.mp4}
MASTER=out/flux-$NAME.mp4
GITHUB=out/flux-$NAME-github.mp4
FADE_IN=${FADE_IN:-0.4}
FADE_OUT=${FADE_OUT:-3}
LIMIT=$((10 * 1000 * 1000))

START=$(jq -r ".videos.$NAME.track_start_s" audio/music.json)
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SILENT")
OUT_AT=$(awk -v d="$DUR" -v f="$FADE_OUT" 'BEGIN { printf "%.3f", d - f }')

ffmpeg -y -loglevel error -ss "$START" -t "$DUR" -i audio/music.mp3 \
  -af "afade=t=in:st=0:d=$FADE_IN,afade=t=out:st=$OUT_AT:d=$FADE_OUT:curve=qsin" \
  -ar 48000 -ac 2 -c:a pcm_s16le "out/music-$NAME.wav"

# The master keeps the video stream as rendered.
ffmpeg -y -loglevel error -i "$SILENT" -i "out/music-$NAME.wav" -map 0:v -map 1:a \
  -c:v copy -c:a aac -b:a 256k -shortest -movflags +faststart "$MASTER"

# The GitHub copy: 720p, two-pass x264 at a bitrate that fits the limit.
AUDIO_KBPS=96
TOTAL_KBPS=$(awk -v l="$LIMIT" -v d="$DUR" 'BEGIN { printf "%d", l * 8 * 0.94 / d / 1000 }')
VIDEO_KBPS=$((TOTAL_KBPS - AUDIO_KBPS))
PASSLOG=out/x264-$NAME
ffmpeg -y -loglevel error -i "$SILENT" -vf "scale=1280:720:flags=lanczos" -c:v libx264 -preset slow \
  -b:v "${VIDEO_KBPS}k" -pass 1 -passlogfile "$PASSLOG" -an -f mp4 /dev/null
ffmpeg -y -loglevel error -i "$SILENT" -i "out/music-$NAME.wav" -map 0:v -map 1:a \
  -vf "scale=1280:720:flags=lanczos" -c:v libx264 -preset slow -b:v "${VIDEO_KBPS}k" -pass 2 -passlogfile "$PASSLOG" \
  -pix_fmt yuv420p -c:a aac -b:a "${AUDIO_KBPS}k" -shortest -movflags +faststart "$GITHUB"
rm -f "$PASSLOG"*

SIZE=$(stat -c %s "$GITHUB")
echo "$MASTER $(du -h "$MASTER" | cut -f1)"
echo "$GITHUB $(du -h "$GITHUB" | cut -f1), video ${VIDEO_KBPS} kbps"
if ((SIZE >= LIMIT)); then
  echo "The GitHub copy is $SIZE bytes, over the 10 MB limit" >&2
  exit 1
fi
