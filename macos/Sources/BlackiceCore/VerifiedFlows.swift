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
// address and port is given that name as a DNS answer would have given it (`facts`). Rules and
// approvals decide the flow as always. What changes: a flow with a host name is spared the lookup,
// and a flow with none, which a run that has read no answer drops as `no_host`, is decided on that
// name. A destination is one app's: it names no other app's flow.
//
// A destination has two times. `checked` is when a lookup or a DNS answer last gave the host that
// address: a flow that passes on a restored name is not a check and leaves it alone (`carry`), so
// `maximumAge` counts from the last check however many restarts came between. `used` is when a flow
// last passed on the destination, checked or carried, and decides which one goes when there is no
// room: the tunnel that is open now stays, whatever the age of its check.
public struct VerifiedFlows: Equatable, Sendable {
    /// How long after a start the last run's destinations name this run's flows. A socket that
    /// sends nothing for longer is looked up as before.
    public static let window: TimeInterval = 120
    public static let limitPerApp = 16
    public static let appLimit = 256
    /// A destination last checked longer ago than this is not read back.
    public static let maximumAge: Double = 30 * 86_400
    /// A destination already kept gets a new time only when it is this far from the one it has.
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

    /// Times of day, seconds since 1970.
    struct Times: Equatable, Sendable {
        /// When a lookup or a DNS answer last gave the host this address.
        var checked: Double
        /// When a flow last passed on the destination.
        var used: Double
    }

    private var apps: [AppIdentity: [Destination: Times]] = [:]
    /// Goes up when there is something new to save.
    public private(set) var revision = 0

    public init() {}

    public var count: Int { apps.values.reduce(0) { $0 + $1.count } }

    /// Keeps a destination this run checked and let a flow through on. An app's 17th takes the
    /// place of the one used longest ago, and so does a 257th app, by its latest. One already
    /// kept gets the new time only when it is `refreshAfter` away from the time it has, so that a
    /// flow let through every few seconds is something new to save once an hour, not each time.
    /// Away on either side: a time written while the clock was ahead is replaced once the clock
    /// is right again.
    public mutating func record(app: AppIdentity, _ destination: Destination, timeOfDay: Double) {
        keep(app: app, destination, Times(checked: timeOfDay, used: timeOfDay), checking: true)
    }

    /// Keeps a destination that the last run checked at `checkedAt` and this run let a flow
    /// through on at `timeOfDay`: used now, and checked when it was. A check by this run is never
    /// replaced by that older one.
    public mutating func carry(app: AppIdentity, _ destination: Destination, checkedAt: Double, timeOfDay: Double) {
        keep(app: app, destination, Times(checked: checkedAt, used: timeOfDay), checking: false)
    }

    private mutating func keep(app: AppIdentity, _ destination: Destination, _ times: Times, checking: Bool) {
        var kept = apps[app] ?? [:]
        if var before = kept[destination] {
            let was = before
            if checking, abs(times.checked - before.checked) >= Self.refreshAfter { before.checked = times.checked }
            if abs(times.used - before.used) >= Self.refreshAfter { before.used = times.used }
            guard before != was else { return }
            kept[destination] = before
        } else {
            if apps[app] == nil, apps.count >= Self.appLimit,
               let oldest = apps.min(by: { Self.lastUse($0.value) < Self.lastUse($1.value) })?.key {
                apps.removeValue(forKey: oldest)
            }
            if kept.count >= Self.limitPerApp, let oldest = kept.min(by: { $0.value.used < $1.value.used })?.key {
                kept.removeValue(forKey: oldest)
            }
            kept[destination] = times
        }
        apps[app] = kept
        revision += 1
    }

    private static func lastUse(_ kept: [Destination: Times]) -> Double { kept.values.map(\.used).max() ?? 0 }

    /// The hosts this app's flows to this address and port were let through for.
    public func names(app: AppIdentity, address: IPAddress, port: UInt16) -> Set<String> {
        Set(checked(app: app, address: address, port: port).keys)
    }

    /// `names`, each with the time of day it was last checked.
    public func checked(app: AppIdentity, address: IPAddress, port: UInt16) -> [String: Double] {
        guard let kept = apps[app] else { return [:] }
        var hosts: [String: Double] = [:]
        for (destination, times) in kept where destination.address == address && destination.port == port {
            hosts[destination.host] = times.checked
        }
        return hosts
    }

    /// A UDP flow's names with what the last run checked for its app, address and port. `names`
    /// and `aliases` are what this run's DNS answers gave the address (DNSNameTable). The hosts
    /// they do not hold are `restored`, each with the time of its check. When the answers gave the
    /// address no name, those hosts name the flow as an answer would have. When they gave it one,
    /// a flow with no host name of its own is still decided on that name (FlowFacts.dnsName takes
    /// exactly one), so the hosts only pass the host and address check, as aliases do.
    public func facts(app: AppIdentity, address: IPAddress, port: UInt16, names: Set<String>,
                      aliases: Set<String>) -> (names: Set<String>, aliases: Set<String>, restored: [String: Double]) {
        let restored = checked(app: app, address: address, port: port).filter { !names.contains($0.key) && !aliases.contains($0.key) }
        guard !restored.isEmpty else { return (names, aliases, [:]) }
        let hosts = Set(restored.keys)
        return names.isEmpty ? (hosts, aliases, restored) : (names, aliases.union(hosts), restored)
    }

    /// Adds every destination of `other`, the one used longest ago first, so that with no room
    /// the ones used last stay. One kept already takes each of the other's times that is
    /// `refreshAfter` away from its own (`record`).
    public mutating func merge(_ other: VerifiedFlows) {
        let entries = other.apps.flatMap { app, kept in kept.map { (app: app, destination: $0.key, times: $0.value) } }
        for entry in entries.sorted(by: { $0.times.used < $1.times.used }) {
            keep(app: entry.app, entry.destination, entry.times, checking: true)
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
        /// When it was last checked, seconds since 1970.
        public let at: Double
        /// When a flow last passed on it, seconds since 1970.
        public let used: Double
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
            for (destination, times) in kept {
                entries.append(SavedVerifiedFlows.Entry(app: AppReference(app), host: destination.host,
                                                        ip: destination.address.destination, port: destination.port,
                                                        at: times.checked, used: times.used))
            }
        }
        entries.sort { ($0.used, $0.at, $0.host, $0.ip, $0.port) < ($1.used, $1.at, $1.host, $1.ip, $1.port) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(SavedVerifiedFlows(flows: entries))
    }

    /// What a file `saved` wrote holds, less the destinations checked longer ago than `maximumAge`
    /// at `timeOfDay`, or after it. A use dated after `timeOfDay` counts as now. nil for a file
    /// this version did not write, or one with an entry that is not valid.
    public init?(saved data: Data, timeOfDay: Double) {
        guard let file = try? JSONDecoder().decode(SavedVerifiedFlows.self, from: data),
              file.version == SavedVerifiedFlows.currentVersion,
              file.flows.count <= Self.limitPerApp * Self.appLimit else { return nil }
        self.init()
        // Used longest ago first, as saved, so the limits keep the ones used last.
        for entry in file.flows {
            guard let app = entry.app.identity, normalizeHost(entry.host) == entry.host, entry.port > 0,
                  entry.at.isFinite, entry.used.isFinite,
                  let address = IPAddress(entry.ip), address.destination == entry.ip, !address.isLinkLocal else { return nil }
            guard entry.at <= timeOfDay, timeOfDay - entry.at <= Self.maximumAge else { continue }
            keep(app: app, Destination(host: entry.host, address: address, port: entry.port),
                 Times(checked: entry.at, used: min(entry.used, timeOfDay)), checking: true)
        }
        revision = 0
    }
}
