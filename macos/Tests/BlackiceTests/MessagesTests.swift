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
private func decodeEdited<Message: CheckedMessage>(_ type: Message.Type, _ message: some CheckedMessage,
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
            // Built field by field: App(identity, path:) leaves out a path validPath refuses.
            event(app: .init(signingID: AppReference(tool).signingID, teamID: AppReference(tool).teamID, path: "/tmp/a\nb")),
            event(app: .init(signingID: AppReference(tool).signingID, teamID: AppReference(tool).teamID,
                             path: String(repeating: "a", count: 2000))),
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

    /// The cdhash event in the eval must stay in the format the daemon sends.
    @Test func evalCDHashEventDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("integrations/eval/events/11.json")
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
        let message = DaemonMessage.event(event(), generation: 3)
        #expect(try Messages.decode(DaemonMessage.self, from: Messages.encode(message)) == message)
        let verdict = DaemonMessage.verdict(.timedOut, eventID: "ev-0a1b2c3d")
        #expect(try Messages.decode(DaemonMessage.self, from: Messages.encode(verdict)) == verdict)
        let reply = AnswerReply(status: .done, reason: "approved", message: "approved", events: ["ev-0a1b2c3d"], released: 2)
        #expect(try Messages.decode(AnswerReply.self, from: Messages.encode(reply)) == reply)
        let pending = PendingReply(events: [PendingSummary(id: "ev-0a1b2c3d", app: AppReference(build), path: nil, host: "example.com",
                                                          ip: "203.0.113.7", port: 443, secondsLeft: 3, connections: 1)],
                                   approvals: [ApprovalSummary(app: AppReference(tool), host: "example.com", secondsLeft: 60)],
                                   denials: [ApprovalSummary(app: AppReference(build), host: "203.0.113.7", secondsLeft: 540)])
        #expect(try Messages.decode(PendingReply.self, from: Messages.encode(pending)) == pending)
        let deciding = pending.deciding(with: try policySnapshot(.ask, generation: 9))
        #expect(deciding.active?.generation == 9 && deciding.active?.mode == .ask && deciding.events == pending.events)
        #expect(deciding.denials == pending.denials)
        #expect(try Messages.decode(PendingReply.self, from: Messages.encode(deciding)) == deciding)
        #expect(try Messages.decode(RegisterRequest.self, from: Messages.encode(RegisterRequest())) == RegisterRequest())
    }

    @Test func thePendingReplyNamesTheConfigurationInForce() throws {
        let configuration = try policySnapshot(.blockAll, generation: 4)
        let active = ActiveConfiguration(configuration)
        #expect(active.configSHA256.count == 64 && active.matches(configuration))
        #expect(!active.matches(try configuration.with(mode: .ask)))
        #expect(!active.matches(try ProviderConfiguration(generation: 4, mode: .blockAll, configText: policyRules + "# more\n")))
        let reply = PendingReply(events: [], approvals: [], active: active)
        let json = String(decoding: try Messages.encode(reply), as: UTF8.self)
        #expect(json.contains(#""active":{"config_sha256":"\#(active.configSHA256)","generation":4,"mode":"block-all"}"#))
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["active"] = ["config_sha256": active.configSHA256, "generation": 0, "mode": "block-all"] },
            { $0["active"] = ["config_sha256": "x", "generation": 4, "mode": "block-all"] },
            { $0["active"] = ["config_sha256": active.configSHA256.uppercased(), "generation": 4, "mode": "block-all"] },
            { $0["active"] = ["config_sha256": active.configSHA256, "generation": 4, "mode": "allow-all"] },
            { $0["active"] = ["generation": 4, "mode": "block-all"] },
        ]
        for edit in edits {
            #expect(refused { try decodeEdited(PendingReply.self, reply, edit) })
        }
        // A reply with no configuration says the extension holds none.
        #expect(try decodeEdited(PendingReply.self, reply) { $0["active"] = nil }.active == nil)
    }

    @Test func answersOutsideTheirFormAreRefused() {
        let approve = AnswerRequest(kind: .approve, app: tool, host: "example.com", seconds: 600, token: testToken)
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["version"] = Messages.version + 1 },
            { $0["version"] = Messages.version - 1 },
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

    @Test func aPersonsAnswerMayNameOneScript() throws {
        let approve = AnswerRequest(kind: .approve, app: build, host: "sts.amazonaws.com", seconds: 600, token: nil,
                                    script: "/opt/homebrew/bin/aws")
        #expect(try Messages.decode(AnswerRequest.self, from: Messages.encode(approve)) == approve)
        #expect(approve.scope == .script("/opt/homebrew/bin/aws"))
        let module = AnswerRequest(kind: .deny, app: build, host: "pypi.org", seconds: nil, token: nil, script: "-m pip")
        #expect(try Messages.decode(AnswerRequest.self, from: Messages.encode(module)).scope == .script("-m pip"))
        #expect(AnswerRequest(kind: .deny, app: build, host: "pypi.org", seconds: nil, token: nil).scope == .any)
        // A relative path, control characters, an empty name; and a hook's answer, whose event names its script.
        for script in ["aws", "./aws", "/tmp/a\u{1b}[2Jb", ""] {
            #expect(refused { try decodeEdited(AnswerRequest.self, approve) { $0["script"] = script } })
        }
        let hook = AnswerRequest(kind: .approve, app: build, host: "sts.amazonaws.com", seconds: 600, token: testToken)
        #expect(refused { try decodeEdited(AnswerRequest.self, hook) { $0["script"] = "/opt/homebrew/bin/aws" } })
    }

    @Test func approvalsSayWhichScriptTheyCover() throws {
        let entries = [ApprovalSummary(app: AppReference(build), host: "sts.amazonaws.com", secondsLeft: 60, scope: .script("/opt/homebrew/bin/aws")),
                       ApprovalSummary(app: AppReference(build), host: "sts.amazonaws.com", secondsLeft: 60, scope: .script(nil)),
                       ApprovalSummary(app: AppReference(build), host: "sts.amazonaws.com", secondsLeft: 60)]
        let reply = PendingReply(events: [], approvals: entries, denials: entries)
        let decoded = try Messages.decode(PendingReply.self, from: Messages.encode(reply))
        #expect(decoded == reply && decoded.approvals.map(\.scope) == [.script("/opt/homebrew/bin/aws"), .script(nil), .any])
        let json = String(decoding: try Messages.encode(reply), as: UTF8.self)
        #expect(json.contains(#""no_script":true"#) && json.contains("homebrew"))
        // A script and no script at once, a no_script that is not true, a script with control characters.
        for entry in [["app": ["cdhash": testCDHash], "host": "example.com", "seconds_left": 1, "script": "/a", "no_script": true],
                      ["app": ["cdhash": testCDHash], "host": "example.com", "seconds_left": 1, "no_script": false],
                      ["app": ["cdhash": testCDHash], "host": "example.com", "seconds_left": 1, "script": "/a\u{7}"]]
                as [[String: Any]] {
            #expect(refused { try decodeEdited(PendingReply.self, reply) { $0["approvals"] = [entry] } })
            #expect(refused { try decodeEdited(PendingReply.self, reply) { $0["denials"] = [entry] } })
        }
    }

    @Test func daemonMessagesCarryOnePayload() {
        let message = DaemonMessage.event(event(), generation: 3)
        #expect(refused { try decodeEdited(DaemonMessage.self, message) { $0["verdict"] = "approved" } })
        #expect(refused { try decodeEdited(DaemonMessage.self, message) { $0["event"] = nil } })
        #expect(refused { try decodeEdited(DaemonMessage.self, DaemonMessage.verdict(.denied, eventID: "ev-0a1b2c3d")) {
            $0["event_id"] = "ev-1"
        } })
        // An event the extension would never send is refused with the message.
        #expect(refused { try Messages.decode(DaemonMessage.self, from: Messages.encode(DaemonMessage.event(event(host: nil), generation: 3))) })
    }

    @Test func eventsNameTheirGeneration() throws {
        let message = DaemonMessage.event(event(), generation: 7)
        let decoded = try Messages.decode(DaemonMessage.self, from: Messages.encode(message))
        #expect(decoded.generation == 7)
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["generation"] = nil }, { $0["generation"] = 0 }, { $0["generation"] = -1 }, { $0["generation"] = "7" },
        ]
        for edit in edits {
            #expect(refused { try decodeEdited(DaemonMessage.self, message, edit) })
        }
        // A verdict never carries one.
        #expect(refused { try decodeEdited(DaemonMessage.self, DaemonMessage.verdict(.approved, eventID: "ev-0a1b2c3d")) {
            $0["generation"] = 7
        } })
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
        for denial in [["app": ["cdhash": "x"], "host": "example.com", "seconds_left": 1],
                       ["app": ["cdhash": testCDHash], "host": "*.example.com", "seconds_left": 1],
                       ["app": ["cdhash": testCDHash], "host": "example.com", "seconds_left": -1]] as [[String: Any]] {
            #expect(refused { try decodeEdited(PendingReply.self, pending) { $0["denials"] = [denial] } })
        }
        // A reply from an extension that lists no denials is another protocol version.
        #expect(refused { try decodeEdited(PendingReply.self, pending) { $0["denials"] = nil } })
    }

    @Test func garbageAndOversizedDataAreRefused() {
        #expect(refused { try Messages.decode(PendingRequest.self, from: Data()) })
        #expect(refused { try Messages.decode(PendingRequest.self, from: Data("not json".utf8)) })
        #expect(refused { try Messages.decode(PendingRequest.self, from: Data(count: Messages.maximumBytes + 1)) })
        #expect(refused { try Messages.decode(PendingRequest.self, from: Data(#"{"version":0}"#.utf8)) })
        // The sender holds to the same limit.
        let long = AnswerReply(status: .done, reason: "approved", message: String(repeating: "a", count: Messages.maximumBytes))
        #expect(refused { try Messages.encode(long) })
    }

    /// The most a pending reply can hold: as many events as the extension keeps, each with the
    /// longest path (all of it escaped), identity, host and address, and every approval and denial.
    private static func largestPendingReply() -> PendingReply {
        let signingID = String(repeating: "a", count: 255)
        let app = AppReference(signingID: signingID, teamID: "ABCDE12345", cdhash: nil)
        let label = String(repeating: "h", count: 63)
        let host = [label, label, label, String(repeating: "h", count: 61)].joined(separator: ".")
        let path = String(repeating: "\"\\", count: HookEvent.maximumPathBytes / 2)
        let events = (0..<AskLimits.events).map { index in
            PendingSummary(id: String(format: "ev-%08x", index), app: app, path: path, host: host,
                           ip: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", port: .max, secondsLeft: .max, connections: .max,
                           script: path, title: String(repeating: "\"\\", count: HookEvent.maximumTitleBytes / 2))
        }
        let approvals = (0..<ApprovalTable.maximumEntries).map { _ in
            ApprovalSummary(app: app, host: host, secondsLeft: .max, scope: .script(path))
        }
        return PendingReply(events: events, approvals: approvals, denials: approvals)
    }

    @Test func theLargestPendingReplyFitsAndRoundTrips() throws {
        let largest = Self.largestPendingReply()
        try largest.validate(now: Date())
        #expect(largest.events[0].host.utf8.count == 253 && largest.events[0].path?.utf8.count == HookEvent.maximumPathBytes)
        #expect(largest.events[0].script?.utf8.count == HookEvent.maximumPathBytes && largest.approvals[0].script != nil)
        #expect(largest.events[0].title?.utf8.count == HookEvent.maximumTitleBytes)
        // A title past its limit, or with a control character, is no reply of the extension's.
        for title in [String(repeating: "a", count: HookEvent.maximumTitleBytes + 1), "npm\u{7}"] {
            let event = largest.events[0]
            let bad = PendingSummary(id: event.id, app: event.app, path: nil, host: event.host, ip: event.ip, port: event.port,
                                     secondsLeft: 1, connections: 1, title: title)
            #expect(refused { try PendingReply(events: [bad], approvals: []).validate(now: Date()) })
        }
        let data = try Messages.encode(largest)
        #expect(data.count <= PendingReply.maximumBytes)
        #expect(data.count > Messages.maximumBytes, "the old limit refused this reply")
        #expect(try Messages.decode(PendingReply.self, from: data) == largest)
        // Up to the limit, padded with spaces, it is read; one byte more and it is not.
        let padded = data + Data(repeating: 0x20, count: PendingReply.maximumBytes - data.count)
        #expect(try Messages.decode(PendingReply.self, from: padded) == largest)
        #expect(refused { try Messages.decode(PendingReply.self, from: padded + Data([0x20])) })
    }

    @Test func aPendingReplyBeyondTheExtensionsLimitsIsRefused() throws {
        let largest = Self.largestPendingReply()
        let more = PendingReply(events: largest.events + [largest.events[0]], approvals: [])
        #expect(refused { try Messages.decode(PendingReply.self, from: Messages.encode(more)) })
        let tooManyApprovals = PendingReply(events: [], approvals: largest.approvals + [largest.approvals[0]])
        #expect(refused { try Messages.decode(PendingReply.self, from: Messages.encode(tooManyApprovals)) })
        let tooManyDenials = PendingReply(events: [], approvals: [], denials: largest.denials + [largest.denials[0]])
        #expect(refused { try Messages.decode(PendingReply.self, from: Messages.encode(tooManyDenials)) })
        // An address only as the extension writes it: a zone could make it any length.
        let event = PendingSummary(id: "ev-0a1b2c3d", app: AppReference(build), path: nil, host: "example.com",
                                   ip: "fe80::1", port: 443, secondsLeft: 3, connections: 1)
        let zoned = PendingReply(events: [event], approvals: [])
        #expect(try Messages.decode(PendingReply.self, from: Messages.encode(zoned)) == zoned)
        #expect(refused { try decodeEdited(PendingReply.self, zoned) {
            $0["events"] = [["id": "ev-0a1b2c3d", "app": ["cdhash": testCDHash], "host": "example.com",
                             "ip": "fe80::1%" + String(repeating: "x", count: 4096), "port": 443, "seconds_left": 3,
                             "connections": 1]]
        } })
    }

    @Test func peersAreNamedByTeam() {
        #expect(Peers.machServiceName(teamID: "ABCDE12345", build: "16") == "ABCDE12345.com.valentorassa.blackice.filter.16")
        #expect(Peers.clientRequirement(teamID: "ABCDE12345")
            == #"anchor apple generic and identifier "com.valentorassa.blackice" and certificate leaf[subject.OU] = "ABCDE12345""#)
        #expect(Peers.filterRequirement(teamID: "ABCDE12345")
            == #"anchor apple generic and identifier "com.valentorassa.blackice.filter" and certificate leaf[subject.OU] = "ABCDE12345""#)
        #expect(Peers.machServiceName(teamID: "abc", build: "16") == nil)
        #expect(Peers.clientRequirement(teamID: "ABCDE1234\"") == nil)
    }

    /// Each build has its own Mach service, under the app group, so a new build's launchd job never
    /// asks for the name the replaced build's job still holds.
    @Test func eachBuildHasItsOwnMachService() {
        let fifteen = Peers.machServiceName(teamID: "ABCDE12345", build: "15")
        #expect(fifteen != nil && fifteen != Peers.machServiceName(teamID: "ABCDE12345", build: "16"))
        #expect(fifteen?.hasPrefix("ABCDE12345." + BlackiceIdentifiers.host + ".") == true)
        #expect(Peers.machServiceName(teamID: "ABCDE12345", build: "999999999") == "ABCDE12345.com.valentorassa.blackice.filter.999999999")
        for build in ["", "0", "016", "1.2", "1a", "-1", "1000000000", "16\""] {
            #expect(Peers.machServiceName(teamID: "ABCDE12345", build: build) == nil, "build \(build)")
        }
    }

    /// The extension's Info.plist as sign.sh leaves it, and what each side accepts from it.
    @Test func theNameComesFromTheExtensionInfoPlist() {
        func info(_ build: Any?, _ service: Any?) -> [String: Any] {
            var info: [String: Any] = ["CFBundleIdentifier": BlackiceIdentifiers.filter]
            if let build { info["CFBundleVersion"] = build }
            if let service { info["NetworkExtension"] = ["NEMachServiceName": service] }
            return info
        }
        let signed = "ABCDE12345.com.valentorassa.blackice.filter.16"
        #expect(Peers.machServiceName(teamID: "ABCDE12345", extensionInfo: info("16", signed)) == signed)
        // 0.3.2 and earlier: one name for every build.
        #expect(Peers.machServiceName(teamID: "ABCDE12345", extensionInfo: info("15", "ABCDE12345.com.valentorassa.blackice.filter")) == nil)
        // Another build's name, another team's, the unsigned template, or parts missing.
        #expect(Peers.machServiceName(teamID: "ABCDE12345", extensionInfo: info("17", signed)) == nil)
        #expect(Peers.machServiceName(teamID: "VWXYZ67890", extensionInfo: info("16", signed)) == nil)
        #expect(Peers.machServiceName(teamID: "ABCDE12345",
                                      extensionInfo: info("1", "TEAM_ID.com.valentorassa.blackice.filter.BUILD")) == nil)
        #expect(Peers.machServiceName(teamID: "ABCDE12345", extensionInfo: info(nil, signed)) == nil)
        #expect(Peers.machServiceName(teamID: "ABCDE12345", extensionInfo: info(16, signed)) == nil)
        #expect(Peers.machServiceName(teamID: "ABCDE12345", extensionInfo: info("16", nil)) == nil)
    }

    /// The CLI and the daemon read the Info.plist of the extension inside their app.
    @Test func theClientReadsTheEmbeddedExtension() throws {
        let app = try makePrivateDirectory().appendingPathComponent("Blackice.app", isDirectory: true)
        defer { removeTree(app.deletingLastPathComponent()) }
        #expect(Peers.machServiceName(teamID: "ABCDE12345", app: app) == nil)
        #expect(Peers.extensionBuild(app: app) == nil)

        let plist = app.appendingPathComponent(Peers.embeddedExtensionInfo)
        #expect(plist.path.hasSuffix("Blackice.app/Contents/Library/SystemExtensions/" +
                                     "com.valentorassa.blackice.filter.systemextension/Contents/Info.plist"))
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleVersion": "16",
                                   "NetworkExtension": ["NEMachServiceName": "ABCDE12345.com.valentorassa.blackice.filter.16"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        #expect(Peers.machServiceName(teamID: "ABCDE12345", app: app) == "ABCDE12345.com.valentorassa.blackice.filter.16")
        #expect(Peers.extensionBuild(app: app) == "16")

        try Data("not a plist".utf8).write(to: plist)
        #expect(Peers.machServiceName(teamID: "ABCDE12345", app: app) == nil)
        #expect(Peers.extensionBuild(app: app) == nil)
    }
}

struct RegisterReplyTests {
    private static let text = """
    mode = "ask"
    timeout_seconds = 20

    [[allow]]
    app = "com.example.agent"
    team = "ABCDE12345"
    hosts = ["api.example.com"]

    [[hook]]
    on = "connection"
    run = 'fx ask "Use the blackice skill"'
    """

    @Test func anAcceptedReplyCarriesTheConfiguration() throws {
        let reply = RegisterReply(generation: 12, configText: Self.text)
        let decoded = try Messages.decode(RegisterReply.self, from: Messages.encode(reply))
        #expect(decoded == reply && decoded.accepted)
        let configuration = try RegisterReply.configuration(from: Messages.encode(reply))
        #expect(configuration.generation == 12 && configuration.timeoutSeconds == 20)
        #expect(configuration.hooks == [Hook(on: "connection", run: #"fx ask "Use the blackice skill""#, line: 9)])
        #expect(configuration == (try DaemonConfiguration(generation: 12, configText: Self.text)))
        #expect(configuration.summary == "generation 12, 1 hook, timeout 20 s")
    }

    @Test func aRefusedReplyCarriesNothing() throws {
        let data = try Messages.encode(RegisterReply.refused)
        let decoded = try Messages.decode(RegisterReply.self, from: data)
        #expect(!decoded.accepted && decoded.generation == nil && decoded.config == nil && decoded.configuration == nil)
        #expect(throws: MessageError("registration", "was refused")) { try RegisterReply.configuration(from: data) }
    }

    @Test func everyFieldIsChecked() {
        let accepted = RegisterReply(generation: 12, configText: Self.text)
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["version"] = Messages.version - 1 },
            { $0["generation"] = nil },
            { $0["generation"] = 0 },
            { $0["generation"] = -3 },
            { $0["config"] = nil },
            { $0["config"] = 42 },
            { $0["config"] = "" },
            { $0["config"] = "mode = \"loud\"\n" },
            { $0["config"] = "mode = \"ask\"\n[[hook]]\non = \"connection\"\n" },
            { $0["config"] = "mode = \"ask\"\n" + String(repeating: "#", count: BlackiceConfig.maximumBytes) },
            { $0["accepted"] = "yes" },
            { $0["accepted"] = nil },
        ]
        for edit in edits {
            #expect(refused { try decodeEdited(RegisterReply.self, accepted, edit) })
        }
        // Refused, but with a configuration attached: not a form the extension sends.
        #expect(refused { try decodeEdited(RegisterReply.self, RegisterReply.refused) { $0["generation"] = 3 } })
        #expect(refused { try decodeEdited(RegisterReply.self, RegisterReply.refused) { $0["config"] = Self.text } })
        #expect(refused { try decodeEdited(RegisterReply.self, accepted) { $0["accepted"] = false } })
    }

    @Test func theLargestConfigurationFitsInOneMessage() throws {
        // Quotes and backslashes double in JSON; control characters other than tab never reach here,
        // since the parser refuses them.
        let header = "mode = \"ask\"\n#"
        let text = header + String(repeating: "\"\\", count: (BlackiceConfig.maximumBytes - header.utf8.count) / 2)
        #expect(text.utf8.count <= BlackiceConfig.maximumBytes)
        let data = try Messages.encode(RegisterReply(generation: UInt64.max, configText: text))
        #expect(data.count <= RegisterReply.maximumBytes && RegisterReply.maximumBytes <= Messages.maximumBytes)
        #expect(try RegisterReply.configuration(from: data).generation == UInt64.max)
    }
}
