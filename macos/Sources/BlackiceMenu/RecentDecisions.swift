import Darwin
import Foundation
import BlackiceCore

/// One verdict from the daemon's event log, with the app and host of its event.
public struct RecentDecision: Equatable, Sendable {
    public let verdict: Verdict
    /// Already cleaned for the menu (MenuText).
    public let app: String
    public let host: String
    public let date: Date?

    public init(verdict: Verdict, app: String, host: String, date: Date?) {
        self.verdict = verdict
        self.app = app
        self.host = host
        self.date = date
    }
}

/// The last verdicts in ~/Library/Logs/blackice/events.jsonl. Only the end of the file is read,
/// and it is read again only when its size or modification time changes.
public final class RecentDecisions {
    /// How much of the end of the log is read: some hundred records, a few dozen events.
    public static let tailBytes = 65_536

    private let url: URL
    private var stamp: (size: off_t, modified: timespec)?
    private var cached: [RecentDecision] = []

    public init(url: URL) { self.url = url }

    /// The last `limit` verdicts, newest first; empty when there is no log.
    public func latest(limit: Int) -> [RecentDecision] {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { stamp = nil; cached = []; return [] }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return [] }
        if let stamp, stamp.size == info.st_size, stamp.modified.tv_sec == info.st_mtimespec.tv_sec,
           stamp.modified.tv_nsec == info.st_mtimespec.tv_nsec {
            return Array(cached.prefix(limit))
        }
        let start = max(0, info.st_size - off_t(Self.tailBytes))
        guard lseek(descriptor, start, SEEK_SET) == start else { return [] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = (try? handle.read(upToCount: Self.tailBytes)) ?? Data()
        cached = Self.parse(data, partialFirstLine: start > 0, limit: 32)
        stamp = (info.st_size, info.st_mtimespec)
        return Array(cached.prefix(limit))
    }

    /// The verdicts in `data`, newest first, at most `limit`. A verdict counts only when its event
    /// (`event_received`) is in the same stretch, since that is where the app and host are. Lines
    /// that are not records of the log's shape are skipped; when the stretch starts inside the
    /// file, its first line is a piece of a record and is skipped too.
    public static func parse(_ data: Data, partialFirstLine: Bool, limit: Int) -> [RecentDecision] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if partialFirstLine, !lines.isEmpty, data.first != 0x0A { lines.removeFirst() }
        var events: [String: (app: String, host: String)] = [:]
        var verdicts: [(id: String, verdict: Verdict, date: Date?)] = []
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, let id = object["event"] as? String, validEventID(id) else { continue }
            switch type {
            case "event_received":
                let identity: AppIdentity?
                if let signingID = object["app_signing_id"] as? String, validSigningID(signingID) {
                    let team = (object["app_team_id"] as? String).flatMap { validTeamID($0) ? $0 : nil }
                    identity = .signed(SigningIdentity(signingID: signingID, teamID: team))
                } else if let cdhash = object["app_cdhash"] as? String, validCDHash(cdhash) {
                    identity = .cdhash(cdhash)
                } else {
                    identity = nil
                }
                let host = (object["host"] as? String).map(MenuText.host) ?? (object["ip"] as? String).map(MenuText.host)
                events[id] = (MenuText.appName(path: object["app_path"] as? String, identity: identity), host ?? "unknown host")
            case "verdict":
                guard let raw = object["verdict"] as? String, let verdict = Verdict(rawValue: raw) else { continue }
                verdicts.append((id, verdict, (object["ts"] as? String).flatMap(date)))
            default:
                continue
            }
        }
        var result: [RecentDecision] = []
        for entry in verdicts.reversed() {
            guard let event = events[entry.id] else { continue }
            result.append(RecentDecision(verdict: entry.verdict, app: event.app, host: event.host, date: entry.date))
            if result.count == limit { break }
        }
        return result
    }

    /// The log's timestamps: ISO 8601 with fractional seconds.
    static func date(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
}
