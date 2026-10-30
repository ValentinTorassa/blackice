import Foundation

var assertions = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
}
func rejects(_ values: [String]) {
    do { _ = try ProbeOptions.parse(values); expect(false, "rejected unsafe/invalid arguments") }
    catch { expect(true, "rejected unsafe/invalid arguments") }
}

do {
    let urls = ["https://example.com/", "https://httpbingo.org/status/200"]
    if case .cli(let targets) = try ProbeOptions.parse(urls + [urls[0]]) {
        expect(targets.count == 3 && targets[2].label == "request_3", "three sequential evidence targets")
    } else { expect(false, "CLI mode") }
    if case .check(let targets) = try ProbeOptions.parse(["--check"] + urls) {
        expect(targets.count == 2, "read-only input check")
    } else { expect(false, "check mode") }
    if case .gui(let targets) = try ProbeOptions.parse([]) {
        expect(targets.map { $0.label } == ["Service", "Telemetry"], "GUI has two explicit test roles")
    } else { expect(false, "GUI mode") }
    if case .help = try ProbeOptions.parse(["--help"]) { expect(true, "help mode") }
    else { expect(false, "help mode") }
    for invalid in ["http://example.com/", "file:///tmp/probe", "https://owner:secret@example.com/",
                    "https://example.com/?token=synthetic", "https://example.com/#fragment",
                    "https://example.com:8443/", "https://127.0.0.1/", "https://[::1]/", "https://127.1/",
                    "https://host.0x7f/", "https://host.0x/", "https://exa_mple.com/", "https://a..com/",
                    "https://example.com/\n", "https://" + String(repeating: "a", count: 2048) + ".com/"] {
        rejects([invalid, urls[0]])
    }
    for values in [[urls[0]], urls + urls, ["--check"], ["--gui", urls[0]], ["--unknown", urls[0]]] { rejects(values) }

    let verified = ProbeTransportEvidence(protocolName: "h2", tls: true, reused: false, proxy: false, networkLoad: true, transactions: 1)
    expect(verified.verifiedTCP, "TLS HTTP/2 fresh network connection is evidence")
    expect(ProbeResult.classify(errorCode: nil, refusal: nil, status: 200, evidence: verified) == "http_response", "success needs real transport metrics")
    for name in ["h3", "h3-29", "quic", "", "unknown"] {
        var candidate = verified; candidate.protocolName = name
        expect(!candidate.verifiedTCP, "never call QUIC or missing metrics TCP evidence")
        expect(ProbeResult.classify(errorCode: nil, refusal: nil, status: 200, evidence: candidate) == "transport_unverified", "reject unsupported transport result")
    }
    var http1 = verified; http1.protocolName = "http/1.1"
    expect(http1.verifiedTCP, "TLS HTTP/1.1 also supported")
    for field in 0..<5 {
        var candidate = verified
        switch field {
        case 0: candidate.tls = false
        case 1: candidate.reused = true
        case 2: candidate.proxy = true
        case 3: candidate.networkLoad = false
        default: candidate.transactions = 2
        }
        expect(!candidate.verifiedTCP, "TLS, fresh connection, no proxy, network load and one transaction required")
    }
    expect(ProbeResult.classify(errorCode: -1009, refusal: nil, status: nil, evidence: verified) == "network_error", "network error is not labeled filter denial")
    expect(ProbeResult.classify(errorCode: -999, refusal: "redirect_refused", status: 302, evidence: verified) == "redirect_refused", "redirect refusal survives cancellation")
    expect(ProbeResult.classify(errorCode: -999, refusal: "response_limit", status: 200, evidence: verified) == "response_limit", "large response is not a success")
    let result = ProbeResult(label: "request_1", host: "example.com", outcome: "http_response", status: 200,
                             networkProtocol: "h2", tls: true, freshTCP: true, bytes: 12, durationMS: 5, errorCode: nil)
    let output = try JSONSerialization.jsonObject(with: probeJSON(result)) as! [String: Any]
    expect(result.succeeded && output["kind"] as? String == "probe_result", "client observations labeled distinctly from receipts")
    expect(output["verdict"] == nil && output["url"] == nil && output["body"] == nil && output["error_code"] == nil, "no invented verdict, URL, body or absent error field")
    print("PASS: \(assertions) offline probe assertions; no network, keychain, window or filter action")
} catch {
    FileHandle.standardError.write(Data("FAIL: unexpected probe fixture error\n".utf8)); exit(1)
}
