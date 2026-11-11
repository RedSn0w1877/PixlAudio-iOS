#!/usr/bin/env bash
# Extra check of the Opus remux with ffmpeg's own tools (not in CI; needs ffmpeg and ffprobe on the PATH).
# The PixlCore test `OpusRemuxTests.dumpsFilesForTheFFmpegCheck` writes the test WebM files and our MP4s into
# PIXL_OPUS_DUMP_DIR; then for each pair:
#   - ffprobe must read the MP4 as Opus, 48 kHz, with the pre-skip as initial_padding and a duration of exactly the
#     valid samples (the edit list);
#   - the MP4's decode must be identical, sample for sample, to the WebM's decode (ffmpeg applies the WebM's
#     CodecDelay and DiscardPadding). ffmpeg's MP4 reader cuts the start of the edit list but not its end, so its
#     MP4 decode carries the end padding after the valid samples: only the valid samples are compared, and the
#     padding is reported.
# Usage, from the repository root (Git Bash on Windows, or macOS): bash tools/opus/check-remux.sh
set -euo pipefail

out="$(mktemp -d)"
if [ "${OS:-}" = "Windows_NT" ]; then
  PIXL_OPUS_DUMP_DIR="$(cygpath -w "$out")" cmd //c "ci\\swiftw.cmd test --package-path Packages\\PixlCore --filter OpusRemuxTests" >/dev/null
else
  PIXL_OPUS_DUMP_DIR="$out" swift test --package-path Packages/PixlCore --filter OpusRemuxTests >/dev/null
fi

status=0
for name in fixture laced-unknown-size; do
  webm="$out/$name.webm"
  mp4="$out/$name.mp4"
  [ -f "$mp4" ] || { echo "$name: no MP4 was written"; status=1; continue; }
  echo "== $name"
  ffprobe -v error -show_entries stream=codec_name,sample_rate,channels,initial_padding,duration_ts,duration \
    -of default=noprint_wrappers=1 "$mp4"
  webm_bytes=$(ffmpeg -v error -i "$webm" -f s16le - | wc -c)
  mp4_bytes=$(ffmpeg -v error -i "$mp4" -f s16le - | wc -c)
  channels=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$mp4")
  duration_ts=$(ffprobe -v error -select_streams a:0 -show_entries stream=duration_ts -of csv=p=0 "$mp4")
  frames=$((webm_bytes / (2 * channels)))
  webm_sum=$(ffmpeg -v error -i "$webm" -f s16le - | md5sum | cut -d' ' -f1)
  mp4_sum=$(ffmpeg -v error -i "$mp4" -f s16le - | head -c "$webm_bytes" | md5sum | cut -d' ' -f1)
  echo "WebM decodes to $frames frames; the MP4 says $duration_ts; ffmpeg's MP4 decode adds $(((mp4_bytes - webm_bytes) / (2 * channels))) padded frames at the end"
  if [ "$duration_ts" != "$frames" ]; then echo "FAIL: duration"; status=1; fi
  if [ "$webm_sum" = "$mp4_sum" ]; then echo "OK: identical decode ($webm_sum)"; else echo "FAIL: decodes differ"; status=1; fi
done
rm -rf "$out"
exit $status
