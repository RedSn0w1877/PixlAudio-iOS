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
  tags `ack|read|consent|save|target`). Spec 5 adds the events `approve(peer,vid)`, `republish(vid)`, `offerRead(peer,now)`,
  `offerReadLost(peer)`, `offerPrefetched(peer,vid,key)`, `offerGone(peer)` and gives `tap` a third argument (this phone's
  time); `go` is gone. A state line may end with extra ` tgt=N read=1 tapseen=1 acked=1 beamdone=1 pre=1` words.
- detector.jsonl: `detector`: in `profile` (`normal` or `high`, spec 6) and samples `"t,rssi,impulseMs"` from `DetectorState.INITIAL`, fed to
  `step(state, sample, impulse, profile)`; each step is `"fire,glow,baselineQ,fastQ,near"` (fire is `none`, `impulse`, `dwell` or, from
  spec 5, `hold`). The rssi is already NORMALISED to the iPhone scale (the Android app adds its `rssiOffsetDb` before the core; an
  iPhone adds nothing). Also `tuning` (the constants of each profile), `gates` (the constants of the gates and the hold), `glow` and `floorDiv`.
- impulse.jsonl: `impulse`: in `profile` and samples `"t,x,y,z"` from `ImpulseState.INITIAL`; the jerk threshold is the profile's `jerkMilliG`; out `hits` 0/1.
- peertap.jsonl (spec 6): `peerTap`: in `dbm` (own smoothed normalised signal for the peer, whole dBm), `followed`, `yes`, `now`, `last` (-1 = never);
  out `verdict` (`accept`, `too_weak`, `not_followed`, `no_yes`, `too_soon`, checked in that order: followed, yes, signal at least `minDbm`, gap at least `minGapMs`). `constants` has `minDbm` and `minGapMs`.
- ratelimit.jsonl: `limits`: ops `admit,now,videoId,key`, `accepted,now,videoId`, `attempted,now`, `undone,now,key`
  from an empty `RateLimits`; out `verdicts` (`-` for the two that return no verdict).
- timeline.jsonl: `ease`, `frame` (role, t, reduced), `total`.
- wire.jsonl: the Bluetooth wire format (`SongTapWire`): `constants` (the UUIDs), `infoEncode`, `infoDecode`,
  `helloEncode`, `ackEncode`, `declineEncode`, `goEncode`, `tapEncode`, `controlDecode` (`kind` hello, ack, decline,
  tap or none), `isGo`, `roleOfService` (case sensitive). Spec 5 adds `offerReadyEncode`, `isOfferReady`, `offerWithdrawnEncode`, `isOfferWithdrawn`, `nameEncode`
  (hex of the Name characteristic value for a raw name), `advertEncode` (hex of the manufacturer block data for a raw name),
  `nameDecode` and `advertDecode` (`name` = the clean name or null), and the `constants` line has the name characteristic,
  the two event ids and the advertisement's company id and version. Spec 6 adds `tapEventEncode` (`04`) and `isTapEvent`, and `eventTap` in `constants`.
- names.jsonl (spec 5): `clean` (raw `name` to `name`), `orFallback`, `advertName` (the cut for the advertisement), `isValid`
  (`valid`), `fromAdvert` (`name` or null). Names are worked on as Unicode scalars: at most 20, control, zero width and
  bidirectional characters stripped, spaces collapsed and trimmed, the advert name cut at a scalar boundary to 24 UTF-8 bytes.
- nearby.jsonl (spec 5): `nearby`: ops from an empty `NearbyBook`: `u,id,name,role,fastQ,near,now` (update), `r,id` (remove),
  `c` (clear), `i,id,now` (ignore), `v,role,now` (visible) and `p,role,now` (promptFor); out `results` has one string per
  op: `-` for the mutating ops, rows `id:name:dbm:near` joined by `|` for `v` (`[]` when empty), `id` or `-` for `p`.
- haptics.jsonl: `cues`. handshake.jsonl: `constants`, `impulseAge`, `peerImpulse` (`senderStart` and `receiverStart` are gone in spec 5).

## Pixl ring code (the ring-*.jsonl files; handoff/2026-11-21-ring-code.md)

- ring-layout.jsonl: `constants` (the geometry in permille of the plate half-size, ring sizes, the orange
  start dot colour as a signed Int32), `slot` (slot id to ring, index, count, microTurns = index*1e6/count
  rounded down, byte, bit), `codewordToSlots` / `slotsToCodeword` (25 bytes hex to 200 characters of 0/1).
- ring-rs.jsonl: `gfMul`, `gfInv` (GF(256), polynomial 0x11D), `rsEncode` (11 data bytes to the 25-byte word,
  data then 14 parity bytes, generator roots alpha^0..alpha^13), `rsDecode` (`received` hex, `erasures` positions;
  out `ok` and the corrected `codeword` and `corrected` (unknown-position errors repaired); includes words
  beyond capacity, where a port must give the same answer as the listed one: `ok:false`, or the same miscorrection).
- ring-payload.jsonl: `pack` (id, bucket, random to the 11 data bytes, null when invalid), `encodeSlots`
  (the 200 slot bits), `unpack` (11 bytes to id/bucket/random or the reject reason), `bucketOf`, `freshness`.
- ring-timeline.jsonl: `frame` (scenario, t, approachStart, approachEnd, beamStart in ms with
  -9223372036854775808 = NONE, reduced; out `frame` = RingFrameBuffer.describe(), `progressChecksum` =
  sum of slotProgress * (slot id + 1), `samples` = slotProgress of nine fixed slots, `marker`), `slotStart`,
  `beamTotal`, `sway` (idle angle and breath), `easeNoop`.
The image side of the ring code (renderer, scanner, style) is floating point and has no goldens.
