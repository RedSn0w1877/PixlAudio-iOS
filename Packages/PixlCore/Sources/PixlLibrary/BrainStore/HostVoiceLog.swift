// The developer log of the spoken host (Settings > Endless Listening > Host voice log, developer mode only): the last `HostVoice.logSize`
// decisions, newest first, and the plain line each one reads as. The port of Android's `HostVoiceLog`. Nothing is stored on disk and
// nothing leaves the phone; it is for calibrating the host on a real phone.

/// One decision of the spoken host: `spoke` says the line was said to the end, `cancelled` that it was started and stopped early; otherwise
/// it was skipped. `reason` is the stable word of `HostVoice` ("transition", "too_soon", "skip", ...), "speak" for a line said, "test" for
/// the settings' test. `text` is the line (cut for display only).
public struct HostVoiceLogEntry: Sendable, Equatable {
    public let atMs: Int64
    public let spoke: Bool
    public let cancelled: Bool
    public let reason: String
    public let text: String

    public init(atMs: Int64, spoke: Bool, cancelled: Bool, reason: String, text: String) {
        self.atMs = atMs
        self.spoke = spoke
        self.cancelled = cancelled
        self.reason = reason
        self.text = text
    }
}

public enum HostVoiceLog {
    /// `log` with `entry` in front, at most `HostVoice.logSize` long. The list it was given is not changed.
    public static func add(_ log: [HostVoiceLogEntry], _ entry: HostVoiceLogEntry) -> [HostVoiceLogEntry] {
        var out: [HostVoiceLogEntry] = []
        out.reserveCapacity(min(log.count + 1, HostVoice.logSize))
        out.append(entry)
        for e in log {
            if out.count >= HostVoice.logSize { break }
            out.append(e)
        }
        return out
    }

    /// One line of the log as the developer row shows it, without the time.
    public static func describe(_ e: HostVoiceLogEntry) -> String {
        let what: String
        if e.spoke {
            what = "spoke"
        } else if e.cancelled {
            what = "stopped: \(e.reason)"
        } else {
            what = "skipped: \(e.reason)"
        }
        return e.text.isEmpty ? what : "\(what), \"\(e.text)\""
    }
}
