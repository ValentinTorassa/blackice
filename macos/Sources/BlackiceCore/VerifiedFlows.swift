import Foundation

// The UDP flows a run let through on a host's name, for the next run (docs/plan.md, "A restart with a
// VPN up").
//
// A filter that has just started is given the next datagram of each open UDP socket as a new flow, so
// what the last run let through is decided again by a run that has read no DNS answer yet. For a flow
// that a host rule or an approval covers, that meant blackice's own lookup of the host, with the flow
// paused meanwhile. When the flow is a VPN client's own, the lookup goes into the tunnel the paused
// flow carries, and neither can finish. On 10 November 2026 an upgrade did that to the AWS VPN
// Client, which a rule for `*.amazonaws.com` covers: the lookup of its server's name got no answer
// for 30 s, the flow was dropped as `address_mismatch`, and with the tunnel dead and the Mac's DNS
// server behind it, no name resolved for most of the next 8 minutes.
//
// So a run keeps the destinations of the UDP flows it let through because a rule, the Apple services
// table or an approval named their host, once host and address had checked out, and saves them. The
// next run reads them, and for its first `window` seconds a UDP flow of the same app to the same
// address and port is given that name as a DNS answer would have given it (FlowFacts.dnsNames).
// Rules and approvals decide the flow as always; only the lookup is spared, for a pair the last run
// had checked. A destination is one app's: it names no other app's flow.
public struct VerifiedFlows: Equatable, Sendable {
    /// How long after a start the last run's destinations name this run's flows. A socket that
    /// sends nothing for longer is looked up as before.
    public static let window: TimeInterval = 120
    public static let limitPerApp = 16
    public static let appLimit = 256
    /// A destination last let through longer ago than this is not read back.
    public static let maximumAge: Double = 30 * 86_400
    /// A destination already kept is dated again only once it was let through this much later.
    static let refreshAfter: Double = 3600

    public struct Destination: Hashable, Sendable {
        public let host: String
        public let address: IPAddress
        public let port: UInt16

        public init(host: String, address: IPAddress, port: UInt16) {
            self.host = host
            self.address = address
            self.port = port
        }
    }

    /// Each app's destinations, with the time of day (seconds since 1970) it was last let through.
    private var apps: [AppIdentity: [Destination: Double]] = [:]
    /// Goes up when there is something new to save.
    public private(set) var revision = 0

    public init() {}

    public var count: Int { apps.values.reduce(0) { $0 + $1.count } }

    /// Keeps a destination. An app's 17th takes the place of the one let through longest ago, and
    /// so does a 257th app, by its latest. One already kept gets the new time only once
    /// `refreshAfter` has gone by since the time it has, so that a flow let through every few
    /// seconds is something new to save once an hour, not each time.
    public mutating func record(app: AppIdentity, _ destination: Destination, timeOfDay: Double) {
        var kept = apps[app] ?? [:]
        if let before = kept[destination] {
            guard timeOfDay - before >= Self.refreshAfter else { return }
        } else {
            if apps[app] == nil, apps.count >= Self.appLimit,
               let oldest = apps.min(by: { ($0.value.values.max() ?? 0) < ($1.value.values.max() ?? 0) })?.key {
                apps.removeValue(forKey: oldest)
            }
            if kept.count >= Self.limitPerApp, let oldest = kept.min(by: { $0.value < $1.value })?.key {
                kept.removeValue(forKey: oldest)
            }
        }
        kept[destination] = timeOfDay
        apps[app] = kept
        revision += 1
    }

    /// The hosts this app's flows to this address and port were let through for.
    public func names(app: AppIdentity, address: IPAddress, port: UInt16) -> Set<String> {
        guard let kept = apps[app] else { return [] }
        return Set(kept.keys.filter { $0.address == address && $0.port == port }.map(\.host))
    }

    /// Adds every destination of `other`, oldest first; one kept already keeps its time unless
    /// the other's is `refreshAfter` later (`record`).
    public mutating func merge(_ other: VerifiedFlows) {
        let entries = other.apps.flatMap { app, kept in kept.map { (app: app, destination: $0.key, at: $0.value) } }
        for entry in entries.sorted(by: { $0.at < $1.at }) {
            record(app: entry.app, entry.destination, timeOfDay: entry.at)
        }
    }
}

/// The destinations the extension saves for its next run. The file is root's, mode 0600, beside the
/// approvals.
public struct SavedVerifiedFlows: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public let app: AppReference
        public let host: String
        /// As IPAddress.destination prints it.
        public let ip: String
        public let port: UInt16
        /// Seconds since 1970.
        public let at: Double
    }

    public let version: Int
    public let flows: [Entry]

    public init(flows: [Entry]) {
        version = Self.currentVersion
        self.flows = flows
    }
}

extension VerifiedFlows {
    public func saved() -> Data? {
        var entries: [SavedVerifiedFlows.Entry] = []
        for (app, kept) in apps {
            for (destination, at) in kept {
                entries.append(SavedVerifiedFlows.Entry(app: AppReference(app), host: destination.host,
                                                        ip: destination.address.destination, port: destination.port, at: at))
            }
        }
        entries.sort { ($0.at, $0.host, $0.ip, $0.port) < ($1.at, $1.host, $1.ip, $1.port) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(SavedVerifiedFlows(flows: entries))
    }

    /// What a file `saved` wrote holds, less the destinations older than `maximumAge` at
    /// `timeOfDay` or dated after it. nil for a file this version did not write, or one with an
    /// entry that is not valid.
    public init?(saved data: Data, timeOfDay: Double) {
        guard let file = try? JSONDecoder().decode(SavedVerifiedFlows.self, from: data),
              file.version == SavedVerifiedFlows.currentVersion,
              file.flows.count <= Self.limitPerApp * Self.appLimit else { return nil }
        self.init()
        // Oldest first, as saved, so the limits keep the latest.
        for entry in file.flows {
            guard let app = entry.app.identity, normalizeHost(entry.host) == entry.host, entry.port > 0, entry.at.isFinite,
                  let address = IPAddress(entry.ip), address.destination == entry.ip, address.isCheckable else { return nil }
            guard entry.at <= timeOfDay, timeOfDay - entry.at <= Self.maximumAge else { continue }
            record(app: app, Destination(host: entry.host, address: address, port: entry.port), timeOfDay: entry.at)
        }
        revision = 0
    }
}
