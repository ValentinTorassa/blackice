import Darwin
import Foundation
import BlackiceCore

// `blackice report`'s check on the flow lines. Every event the daemon receives comes from a
// `flow ask` line of the filter, so over the same time the system log should hold at least as many
// ask lines as the daemon's event log (events.jsonl) holds `event_received` records. When it holds
// fewer, macOS dropped some of the filter's lines, as it does when the disk is nearly full, and
// the report's counts are low.

/// The daemon's `event_received` records over the report's window, from its event log.
public enum ReceivedEvents {
    /// Events from the window's first seconds are left out. `log show --last` starts its window a
    /// moment after the report takes the time, so their ask lines can fall just before it.
    public static let margin: TimeInterval = 10

    /// How much of the log is read at a time, from its end back.
    public static let chunkBytes = 65_536
    /// A piece longer than this with no newline is not a record (the longest are a few kilobytes),
    /// and is not kept for the next chunk.
    static let maximumLineBytes = 1 << 20

    /// The records counted against `log show --last` over `minutes`, run right after `now`: from
    /// `margin` after the span's start up to `now`. An event logged after `now` is left out even
    /// when `log show` has its ask line, so the check errs toward saying nothing.
    public static func window(minutes: Int, before now: Date) -> ClosedRange<Date> {
        now.addingTimeInterval(-60 * TimeInterval(minutes) + margin)...now
    }

    /// What some lines of the log hold for a window.
    struct Tally: Equatable {
        /// `event_received` records stamped in the window.
        var received = 0
        /// Whether a record stamped before the window was among them. The log is appended to in
        /// time order, so nothing before that record counts either.
        var reachedStart = false
    }

    /// The `event_received` records in `lines` (a record a line) stamped in `window`. Lines that
    /// are not records of the log's shape, or have no time stamp, are skipped.
    static func tally(_ lines: [Data], in window: ClosedRange<Date>) -> Tally {
        var tally = Tally()
        for line in lines where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let stamp = (object["ts"] as? String).flatMap(date) else { continue }
            if stamp < window.lowerBound {
                tally.reachedStart = true
            } else if stamp <= window.upperBound, object["type"] as? String == "event_received" {
                tally.received += 1
            }
        }
        return tally
    }

    /// The `event_received` records of the log at `url` stamped in `window`. The log is read from
    /// its end back, `chunkBytes` at a time, until a record from before the window. nil when there
    /// is no log, or it cannot be read.
    public static func count(url: URL, in window: ClosedRange<Date>, chunkBytes: Int = ReceivedEvents.chunkBytes) -> Int? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        var received = 0
        var offset = info.st_size
        // The start of the chunk read last, up to its first newline: the end of a line that
        // began in the chunk before it.
        var carried = Data()
        while offset > 0 {
            let length = Int(min(off_t(chunkBytes), offset))
            offset -= off_t(length)
            var chunk = Data(count: length)
            let read = chunk.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, length, offset) }
            guard read == length else { return nil }
            chunk.append(carried)
            var lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
            // Unless the chunk starts the file, its first line may have begun before it.
            carried = offset > 0 ? lines.removeFirst() : Data()
            if carried.count > maximumLineBytes { carried = Data() }
            let tally = tally(lines, in: window)
            received += tally.received
            if tally.reachedStart { break }
        }
        return received
    }

    /// The log's time stamps: ISO 8601 in UTC, with milliseconds.
    static func date(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
}
