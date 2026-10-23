// Sing's preview piece (the "clip job", Sing step 4): when a Sing tap sends a song with no instrumental to the cloud, a
// minute of it around the playhead goes up as a job of its own, ahead of the full song, so the vocals can go off in
// about half a minute instead of one and a half. To the worker it is just a short song (no schema or worker change):
// the clip is decoded from the same source as the full job, sent first in the same burst, and its instrumental is played
// at its place in the song until the full one lands. Pure rules here; `CloudStudio` and the player do the I/O.

import Foundation

/// A stretch of a song, in song time (ms): `[startMs, endMs)`.
public struct CloudClipRange: Sendable, Hashable, Codable {
    public var startMs: Int64
    public var endMs: Int64

    public init(startMs: Int64, endMs: Int64) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMs: Int64 { max(endMs - startMs, 0) }

    /// The song time `songMs` falls inside the clip.
    public func contains(_ songMs: Int64) -> Bool { songMs >= startMs && songMs < endMs }

    /// Where song time `songMs` is in the clip's own audio (the offset mapping: clip time = song time − start), or nil
    /// outside the clip.
    public func clipTimeMs(forSongMs songMs: Int64) -> Int64? { contains(songMs) ? songMs - startMs : nil }

    /// The song time of the clip's own time `clipMs`.
    public func songTimeMs(forClipMs clipMs: Int64) -> Int64 { startMs + clipMs }
}

public enum CloudSingClip {
    /// The clip starts this far before the playhead (the switch lands a little after the tap, and a short seek back
    /// stays covered).
    public static let leadInMs: Int64 = 3_000
    /// …and reaches this far past it (about a minute of singing while the full song is separated).
    public static let afterPlayheadMs: Int64 = 60_000
    /// A song shorter than this goes as a whole only: the full job is about as quick as a clip.
    public static let minimumSongMs: Int64 = 75_000
    /// With less than this left after the playhead there is nothing worth a clip.
    public static let minimumRemainingMs: Int64 = 20_000

    /// The sample frame (at the worker's 44.1 kHz) a song time falls on: where the phone cuts the clip out of its decode
    /// and where the player puts it back, so the two agree to the frame.
    public static func frame(ms: Int64, sampleRate: Int64 = CloudImportCheck.workerSampleRate) -> Int64 {
        max(ms, 0) * sampleRate / 1000
    }

    /// The clip for a Sing tap at `playheadMs`: `[playhead − 3 s, playhead + 60 s]` clamped to the song, or nil when
    /// the song is too short or the playhead too close to the end (the full job alone, then).
    public static func range(playheadMs: Int64, songDurationMs: Int64) -> CloudClipRange? {
        guard songDurationMs >= minimumSongMs else { return nil }
        let playhead = min(max(playheadMs, 0), songDurationMs)
        guard songDurationMs - playhead >= minimumRemainingMs else { return nil }
        let start = max(playhead - leadInMs, 0)
        let end = min(playhead + afterPlayheadMs, songDurationMs)
        guard end > start else { return nil }
        return CloudClipRange(startMs: start, endMs: end)
    }

    /// A Sing tap that joins `fullJob` (already on its way) still gets a clip: when the job is for the instrumental,
    /// the worker has not started it (it is at most waiting in RunPod's queue) and the song has no clip on its way.
    public static func mayAddClip(to fullJob: CloudJobRecord, jobs: [CloudJobRecord]) -> Bool {
        guard !fullJob.isClip, fullJob.tasks.contains(.instrumental),
              fullJob.state.isBeforeSubmit || fullJob.state == .submitted else { return false }
        return !jobs.contains { $0.isClip && $0.songId == fullJob.songId && $0.state.isPending }
    }

    /// The song's full job, which a clip goes ahead of (the latest one of its batch that is not a clip).
    public static func fullJob(of clip: CloudJobRecord, in jobs: [CloudJobRecord]) -> CloudJobRecord? {
        jobs.last { !$0.isClip && $0.songId == clip.songId && $0.batchId == clip.batchId }
    }

    /// A clip that would end its burst is sent as not the last when its full job is right behind it (being prepared or
    /// uploaded, no retry pending): the full job then arrives while the worker is still up and goes out as the last of
    /// the same burst, so the worker stays warm for it instead of stopping after the clip and paying a second cold start.
    /// A full job that is waiting out a retry, finished, or not coming makes the clip the last as usual.
    public static func fullJobFollows(_ clip: CloudJobRecord, jobs: [CloudJobRecord], nowMs: Int64) -> Bool {
        guard clip.isClip, let full = fullJob(of: clip, in: jobs), full.tasks.contains(.instrumental) else { return false }
        switch full.state {
        case .queued, .preparing, .uploading: return full.isDue(nowMs: nowMs)
        default: return false
        }
    }
}
