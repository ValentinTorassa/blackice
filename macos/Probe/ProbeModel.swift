import Foundation

enum ProbeInputError: Error { case usage, invalidURL }

struct ProbeTarget: Encodable, Sendable {
    let label: String
    let url: URL

    init(label: String, text: String) throws {
        guard text.utf8.count <= 2048, text.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
              let parts = URLComponents(string: text), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, let host = parts.host,
              host.utf8.count <= 253, host.contains("."), !host.contains(":"),
              let last = host.split(separator: ".", omittingEmptySubsequences: false).last,
              last.contains(where: { $0.isASCII && $0.isLetter }),
              !(last.lowercased().hasPrefix("0x") && last.dropFirst(2).allSatisfy({ $0.isHexDigit })),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ part in
                  !part.isEmpty && part.utf8.count <= 63 && part.first != "-" && part.last != "-" &&
                  part.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) ||
                      (48...57).contains($0) || $0 == 45 }
              }), let url = parts.url else { throw ProbeInputError.invalidURL }
        self.label = label; self.url = url
    }
}

enum ProbeOptions {
    case help
    case check([ProbeTarget])
    case cli([ProbeTarget])
    case gui([ProbeTarget])

    static func parse(_ args: [String]) throws -> ProbeOptions {
        if args == ["--help"] { return .help }
        if args.isEmpty || args == ["--gui"] {
            return .gui(try targets(["https://example.com/", "https://httpbingo.org/status/200"], gui: true))
        }
        if args.first == "--gui" {
            guard args.count == 3 else { throw ProbeInputError.usage }
            return .gui(try targets(Array(args.dropFirst()), gui: true))
        }
        if args.first == "--check" { return .check(try targets(Array(args.dropFirst()), gui: false)) }
        return .cli(try targets(args, gui: false))
    }

    private static func targets(_ args: [String], gui: Bool) throws -> [ProbeTarget] {
        guard (gui ? args.count == 2 : (1...3).contains(args.count)) else { throw ProbeInputError.usage }
        return try args.enumerated().map {
            try ProbeTarget(label: gui ? ($0.offset == 0 ? "Service" : "Telemetry") : "request_\($0.offset + 1)", text: $0.element)
        }
    }
}

struct ProbeTransportEvidence: Sendable {
    var protocolName: String? = nil
    var tls = false
    var reused = false
    var proxy = false
    var networkLoad = false
    var transactions = 0

    var verifiedTCP: Bool {
        ["http/1.1", "h2"].contains(protocolName ?? "") && tls && !reused && !proxy && networkLoad && transactions == 1
    }
}

/// Client observations, not filter receipts or proof that a failure was a deny.
struct ProbeResult: Encodable, Sendable {
    let kind = "probe_result"
    let label: String
    let host: String
    let outcome: String
    let status: Int?
    let networkProtocol: String?
    let tls: Bool
    let freshTCP: Bool
    let bytes: Int?
    let durationMS: Int
    let errorCode: Int?
    var startedAt: String? = nil
    var completedAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case kind, label, host, outcome, status, tls, bytes
        case networkProtocol = "network_protocol", freshTCP = "fresh_tcp", durationMS = "duration_ms", errorCode = "error_code"
        case startedAt = "started_at", completedAt = "completed_at"
    }

    static func classify(errorCode: Int?, refusal: String?, status: Int?, evidence: ProbeTransportEvidence) -> String {
        if let refusal { return refusal }
        if errorCode != nil { return "network_error" }
        guard status != nil else { return "missing_http_response" }
        return evidence.verifiedTCP ? "http_response" : "transport_unverified"
    }

    var succeeded: Bool { outcome == "http_response" && status.map { (200...299).contains($0) } == true }

    static func timeout(target: ProbeTarget, startedAt: String, durationMS: Int) -> ProbeResult {
        ProbeResult(label: target.label, host: target.url.host ?? "unavailable", outcome: "watchdog_timeout",
                    status: nil, networkProtocol: nil, tls: false, freshTCP: false, bytes: nil,
                    durationMS: durationMS, errorCode: nil, startedAt: startedAt, completedAt: probeTimestamp())
    }
}

func probeTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

/// The CLI prints only the winning result, on its own thread. A late callback
/// after the watchdog cannot print a second line or disturb the next request.
final class ProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: ProbeResult?

    @discardableResult func complete(_ candidate: ProbeResult) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = candidate
        lock.unlock()
        done.signal()
        return true
    }

    func wait(until deadline: DispatchTime, timeout: @autoclosure () -> ProbeResult) -> ProbeResult {
        if done.wait(timeout: deadline) != .success { complete(timeout()) }
        lock.lock(); defer { lock.unlock() }
        // A callback or this wait's timeout has always supplied the result.
        return result!
    }
}

func probeJSON<T: Encodable>(_ value: T) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // All values are bounded scalar observations; an encoding failure is fatal.
    guard let data = try? encoder.encode(value) else { fatalError("probe_output_encoding_failed") }
    return data + Data([10])
}
