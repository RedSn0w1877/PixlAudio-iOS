#!/usr/bin/env bash
# Prefixes every stdin line with a UTC wall-clock timestamp (HH:MM:SS.mmm), unbuffered, so CI logs show
# where xcodebuild spends its time. Usage: xcodebuild ... 2>&1 | bash ci/timestamp.sh | tee build/x.log
exec perl -MTime::HiRes=time -MPOSIX=strftime -ne '
  BEGIN { $| = 1 }
  my $t = time;
  printf "%s.%03d %s", strftime("%H:%M:%S", gmtime $t), int(($t - int $t) * 1000), $_;
'
