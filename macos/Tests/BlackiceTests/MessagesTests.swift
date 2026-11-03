import Foundation
import Testing
@testable import BlackiceCore

// The XPC messages: what each receiver accepts, and what it refuses before acting on it.

private let tool = AppIdentity.signed(SigningIdentity(signingID: "com.example.tool", teamID: "ABCDE12345"))
private let build = AppIdentity.cdhash(testCDHash)

private func event(app: HookEvent.App = .init(tool, path: "/Applications/Tool.app"), id: String = "ev-0a1b2c3d",
                   token: String = testToken, host: String? = "example.com", ip: String = "203.0.113.7",
                   port: UInt16 = 443, deadlineIn seconds: TimeInterval = 10) -> HookEvent {
    // Whole seconds: messages carry ISO 8601 dates without fractions.
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    return HookEvent(id: id, token: token, app: app, host: host, ip: ip, port: port, deadline: now.addingTimeInterval(seconds))
}

/// Encodes `message`, swaps in raw JSON fields, and decodes as `type`.
private func decodeEdited<Message: CheckedMessage>(_ type: Message.Type, _ message: some Encodable,
                                                   _ edit: (inout [String: Any]) -> Void) throws -> Message {
    var object = try #require(JSONSerialization.jsonObject(with: Messages.encode(message)) as? [String: Any])
    edit(&object)
    return try Messages.decode(type, from: JSONSerialization.data(withJSONObject: object))
}

private func refused(_ body: () throws -> Any) -> Bool {
    do { _ = try body(); return false } catch { return true }
}

struct AppIdentityTests {
    @Test func cdhashForms() {
        #expect(validCDHash(testCDHash))
        #expect(!validCDHash(testCDHash.uppercased()) && !validCDHash(String(testCDHash.dropLast())))
        #expect(!validCDHash(String(repeating: "g", count: 40)) && !validCDHash(String(repeating: "a", count: 64)))
        #expect(normalizeCDHash(testCDHash.uppercased()) == testCDHash)
        #expect(normalizeCDHash("\(testCDHash.dropLast())Z") == nil)
        #expect(normalizeCDHash(String(repeating: "é", count: 20)) == nil)
    }

    @Test func labelsAndReferences() {
        #expect(tool.label == "ABCDE12345/com.example.tool" && build.label == "cdhash/" + testCDHash)
        #expect(IdentityResolution.adHoc(cdhash: testCDHash).appIdentity == build)
        #expect(IdentityResolution.unresolved.appIdentity == nil && IdentityResolution.invalidSignature.appIdentity == nil)
        #expect(AppReference(tool).identity == tool && AppReference(build).identity == build)
        // Exactly one form, and valid.
        #expect(AppReference(signingID: "com.example.tool", teamID: nil, cdhash: testCDHash).identity == nil)
        #expect(AppReference(signingID: nil, teamID: "ABCDE12345", cdhash: testCDHash).identity == nil)
        #expect(AppReference(signingID: nil, teamID: nil, cdhash: nil).identity == nil)
        #expect(AppReference(signingID: "com.example.tool\" or 1", teamID: nil, cdhash: nil).identity == nil)
        #expect(AppReference(signingID: "com.example.tool", teamID: "abc", cdhash: nil).identity == nil)
    }
}

struct HookEventValidationTests {
    @Test func eventsFromTheExtensionPass() throws {
        try event().validate(now: Date())
        try event(app: .init(build, path: "/tmp/build/tool")).validate(now: Date())
        try event(app: .init(signingID: "com.apple.curl", teamID: nil, path: nil), ip: "2001:db8::1").validate(now: Date())
    }

    @Test func everyFieldIsChecked() {
        let now = Date()
        let bad: [HookEvent] = [
            HookEvent(event: "other", id: "ev-0a1b2c3d", token: testToken, app: .init(tool, path: nil), host: "example.com",
                      ip: "203.0.113.7", port: 443, deadline: now.addingTimeInterval(10)),
            event(id: "ev-1"), event(id: "ev-0A1B2C3D"), event(id: "xx-0a1b2c3d"),
            event(token: "short"), event(token: String(testToken.dropLast()) + "!"),
            event(app: .init(signingID: "com.example.tool", teamID: nil, cdhash: testCDHash, path: nil)),
            event(app: .init(signingID: nil, teamID: nil, path: nil)),
            event(app: .init(signingID: nil, teamID: nil, cdhash: "zz", path: nil)),
            event(app: .init(tool, path: "/tmp/a\nb")), event(app: .init(tool, path: String(repeating: "a", count: 2000))),
            event(host: nil), event(host: "Example.com"), event(host: "bad host"),
            event(ip: "example.com"), event(ip: "::ffff:203.0.113.7"), event(port: 0),
            event(deadlineIn: -60), event(deadlineIn: 3600),
        ]
        for candidate in bad {
            #expect(refused { try candidate.validate(now: now) }, "\(candidate)")
        }
    }

    @Test func cdhashEventsHaveTheirOwnShape() throws {
        let built = HookEvent(id: "ev-0a1b2c3d", token: testToken, app: .init(build, path: "/tmp/tool"), host: "example.com",
                              ip: "203.0.113.7", port: 443, deadline: Date(timeIntervalSince1970: 1_793_630_171))
        let json = String(decoding: try built.jsonData(), as: UTF8.self)
        #expect(json.contains(#""app":{"cdhash":"\#(testCDHash)","path":"/tmp/tool"}"#))
        #expect(!json.contains("signing_id") && !json.contains("team_id"))
        #expect(try HookEvent.decode(built.jsonData()).app.identity == build)
    }

    /// The cdhash event in the fx eval must stay in the format the daemon sends.
    @Test func fxEvalCDHashEventDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("integrations/fx/eval/events/11.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        // run.sh adds these two.
        object["token"] = testToken
        object["deadline"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        object["id"] = "ev-0000000b"
        let decoded = try HookEvent.decode(JSONSerialization.data(withJSONObject: object))
        try decoded.validate(now: Date())
        guard case .cdhash = decoded.app.identity else { Issue.record("not a cdhash event"); return }
    }
}

struct MessagesTests {
    @Test func roundTrips() throws {
        let answer = AnswerRequest(kind: .approve, app: build, host: "example.com", seconds: 600, token: testToken)
        #expect(try Messages.decode(AnswerRequest.self, from: Messages.encode(answer)) == answer)
        #expect(answer.authorization == .token)
        let person = AnswerRequest(kind: .deny, app: tool, host: "example.com", seconds: nil, token: nil)
        #expect(person.authorization == .touchID)
        #expect(try Messages.decode(AnswerRequest.self, from: Messages.encode(person)) == person)
        let message = DaemonMessage.event(event())
        #expect(try Messages.decode(DaemonMessage.self, from: Messages.encode(message)) == message)
        let verdict = DaemonMessage.verdict(.timedOut, eventID: "ev-0a1b2c3d")
        #expect(try Messages.decode(DaemonMessage.self, from: Messages.encode(verdict)) == verdict)
        let reply = AnswerReply(status: .done, reason: "approved", message: "approved", events: ["ev-0a1b2c3d"], released: 2)
        #expect(try Messages.decode(AnswerReply.self, from: Messages.encode(reply)) == reply)
        let pending = PendingReply(events: [PendingSummary(id: "ev-0a1b2c3d", app: AppReference(build), path: nil, host: "example.com",
                                                          ip: "203.0.113.7", port: 443, secondsLeft: 3, connections: 1)],
                                   approvals: [ApprovalSummary(app: AppReference(tool), host: "example.com", secondsLeft: 60)])
        #expect(try Messages.decode(PendingReply.self, from: Messages.encode(pending)) == pending)
        #expect(try Messages.decode(RegisterRequest.self, from: Messages.encode(RegisterRequest())) == RegisterRequest())
    }

    @Test func answersOutsideTheirFormAreRefused() {
        let approve = AnswerRequest(kind: .approve, app: tool, host: "example.com", seconds: 600, token: testToken)
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 2 },
            { $0["kind"] = "allow" },
            { $0["host"] = "Example.com" },
            { $0["host"] = "*.example.com" },
            { $0["seconds"] = 0 },
            { $0["seconds"] = 86_401 },
            { $0["seconds"] = nil },
            { $0["token"] = "short" },
            { $0["token"] = nil },
            { $0["authorization"] = "touch_id" },
            { $0["authorization"] = "root" },
            { $0["app"] = ["signing_id": "com.example.tool", "cdhash": testCDHash] },
            { $0["app"] = ["cdhash": "ABC"] },
            { $0["app"] = [String: String]() },
        ]
        for edit in edits {
            #expect(refused { try decodeEdited(AnswerRequest.self, approve, edit) })
        }
        let deny = AnswerRequest(kind: .deny, app: tool, host: "example.com", seconds: nil, token: nil)
        #expect(refused { try decodeEdited(AnswerRequest.self, deny) { $0["seconds"] = 60 } })
        #expect(refused { try decodeEdited(AnswerRequest.self, deny) { $0["token"] = testToken } })
    }

    @Test func daemonMessagesCarryOnePayload() {
        let message = DaemonMessage.event(event())
        #expect(refused { try decodeEdited(DaemonMessage.self, message) { $0["verdict"] = "approved" } })
        #expect(refused { try decodeEdited(DaemonMessage.self, message) { $0["event"] = nil } })
        #expect(refused { try decodeEdited(DaemonMessage.self, DaemonMessage.verdict(.denied, eventID: "ev-0a1b2c3d")) {
            $0["event_id"] = "ev-1"
        } })
        // An event the extension would never send is refused with the message.
        #expect(refused { try Messages.decode(DaemonMessage.self, from: Messages.encode(DaemonMessage.event(event(host: nil)))) })
    }

    @Test func repliesAreCheckedToo() {
        let reply = AnswerReply(status: .refused, reason: "token_unknown", message: "no")
        #expect(refused { try decodeEdited(AnswerReply.self, reply) { $0["reason"] = "Token Unknown" } })
        #expect(refused { try decodeEdited(AnswerReply.self, reply) { $0["message"] = "a\u{1b}[2Jb" } })
        #expect(refused { try decodeEdited(AnswerReply.self, reply) { $0["events"] = ["x"] } })
        let pending = PendingReply(events: [], approvals: [ApprovalSummary(app: AppReference(tool), host: "example.com", secondsLeft: 1)])
        #expect(refused { try decodeEdited(PendingReply.self, pending) {
            $0["approvals"] = [["app": ["cdhash": "x"], "host": "example.com", "seconds_left": 1]]
        } })
    }

    @Test func garbageAndOversizedDataAreRefused() {
        #expect(refused { try Messages.decode(PendingRequest.self, from: Data()) })
        #expect(refused { try Messages.decode(PendingRequest.self, from: Data("not json".utf8)) })
        #expect(refused { try Messages.decode(PendingRequest.self, from: Data(count: Messages.maximumBytes + 1)) })
        #expect(refused { try Messages.decode(PendingRequest.self, from: Data(#"{"version":0}"#.utf8)) })
    }

    @Test func peersAreNamedByTeam() {
        #expect(Peers.machServiceName(teamID: "ABCDE12345") == "ABCDE12345.com.valentorassa.blackice.filter")
        #expect(Peers.clientRequirement(teamID: "ABCDE12345")
            == #"anchor apple generic and identifier "com.valentorassa.blackice" and certificate leaf[subject.OU] = "ABCDE12345""#)
        #expect(Peers.filterRequirement(teamID: "ABCDE12345")
            == #"anchor apple generic and identifier "com.valentorassa.blackice.filter" and certificate leaf[subject.OU] = "ABCDE12345""#)
        #expect(Peers.machServiceName(teamID: "abc") == nil)
        #expect(Peers.clientRequirement(teamID: "ABCDE1234\"") == nil)
    }
}
