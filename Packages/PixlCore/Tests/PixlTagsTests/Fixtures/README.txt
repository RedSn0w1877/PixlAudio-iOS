Test fixtures for PixlTags. Files in this folder are bundled with the test target (Bundle.module, subdirectory "Fixtures").
- tags-android-golden.jsonl: vectors from the Android app's compiled tag helpers (tools/android-reference/TagsGen.java).
- ffmpeg-id3v24.mp3, ffmpeg-id3v23.mp3, ffmpeg.flac, ffmpeg.m4a: files tagged by FFmpeg 8 (commands in
  docs/test-parity/s03d-tags.md). Every other test file is built byte by byte in the tests (TestSupport.swift).
