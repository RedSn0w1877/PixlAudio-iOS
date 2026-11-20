# Song Tap golden vectors

Written by `./gradlew :songtap:generateGolden`. Do not edit by hand. The iOS repo copies this
folder byte for byte to `Fixtures/songtap`; `MANIFEST.sha256` lists every file's SHA-256 and
`SPEC_VERSION` is the version of the pure core they describe.

Format: JSON Lines, one `{"fn", "in", "out"}` object per line. Int64 values are decimal strings,
bytes are lower-case hex strings, every character outside printable ASCII is escaped as `\uXXXX`
(UTF-16 units). A port reads each line, runs the function named by `fn` on `in` and must produce
exactly `out`. Signatures are never part of a golden, only the bytes that are signed.

- payload.jsonl
  - `encode` in: the fields (`v`, `ts`, `yt`, `sp`, `isrc`, `t`, `a`, `d`, `art`; null for absent);
    out: `hex` of the canonical bytes, or null when `encode` returns nothing.
  - `decode` in: `hex`; out: `ok` and the fields, or `ok:false` and a `reason` code. Includes
    hand-made hostile inputs and 800 seeded mutations of valid payloads.
  - `make` in: raw text and ids and `now`; out: `ok` and the cleaned fields and `hex`.
  - `sanitize` in: `text` and `max` (bytes); out: `text`. The text rules on their own.
- link.jsonl: `linkEncode` (hex to `pixlsong1:` text), `linkDecode` (text to hex or null).
- signing.jsonl: `signingBytes` (payload, challenge, ts to hex or null), `frameEncode`,
  `frameDecode`, `senderKey`.
- session.jsonl: `trace`: start from `SessionState.initial(askFirst)`, apply each event; `out.steps`
  has the state description and the effect descriptions after each. Event grammar:
  `name(arg,arg,...)` with the arguments exactly as `SessionEvent.describe()` prints them (roles
  `send`/`receive`, `-` for an empty video id, outcomes `saved|already_had|not_found|failed`, timeout
  tags `ack|read|consent|save`).
- detector.jsonl: `detector`: samples `"t,rssi,impulseMs"` from `DetectorState.INITIAL`; each step is
  `"fire,glow,baselineQ,fastQ,near"`. Also `glow` and `floorDiv`.
- impulse.jsonl: `impulse`: samples `"t,x,y,z"` from `ImpulseState.INITIAL`; out `hits` 0/1.
- ratelimit.jsonl: `limits`: ops `admit,now,videoId,key`, `accepted,now,videoId`, `undone,now,key`
  from an empty `RateLimits`; out `verdicts` (`-` for the two that return no verdict).
- timeline.jsonl: `ease`, `frame` (role, t, reduced), `total`.
- haptics.jsonl: `cues`. handshake.jsonl: `senderStart`, `receiverStart`, `impulseAge`, `peerImpulse`.
