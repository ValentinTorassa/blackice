import Darwin
import Foundation
import Testing
@testable import BlackiceCLI
@testable import BlackiceCore
@testable import BlackiceMenu

private let safari = AppReference(signingID: "com.apple.Safari", teamID: nil, cdhash: nil)
private let vscode = AppReference(signingID: "com.microsoft.VSCode", teamID: "UBF8T346G9", cdhash: nil)

private func summary(_ id: String = "ev-0a1b2c3d", app: AppReference = safari,
                     path: String? = "/Applications/Safari.app/Contents/MacOS/Safari", host: String = "example.com",
                     secondsLeft: Int = 40, connections: Int = 1) -> PendingSummary {
    PendingSummary(id: id, app: app, path: path, host: host, ip: "203.0.113.7", port: 443, secondsLeft: secondsLeft,
                   connections: connections)
}

private let context = MenuContext(version: "0.3.2 (build 15)", login: .off, configExists: true, logExists: true)

/// The configuration saved, as the filter names it.
private func saved(_ mode: Mode, generation: UInt64 = 3) throws -> ActiveConfiguration {
    ActiveConfiguration(try ProviderConfiguration(generation: generation, mode: mode, configText: "mode = \"ask\"\n"))
}

/// The filter's answer to pending, deciding with `active`.
private func answering(_ active: ActiveConfiguration, _ events: [PendingSummary] = []) -> PendingReply {
    PendingReply(events: events, approvals: [], active: active)
}

private func titles(_ entries: [MenuEntry]) -> [String] {
    entries.compactMap { $0.kind == .separator ? nil : $0.title }
}

struct MenuLaunchTests {
    @Test func launchServicesOpensTheMenuAndATerminalGetsTheUsage() {
        // Finder, Spotlight, `open` and login items: launchd's child, no arguments, no terminal.
        #expect(MenuLaunch.opensAsApp(arguments: [], parentPID: 1, terminal: false, inAppBundle: true))
        #expect(MenuLaunch.opensAsApp(arguments: ["-psn_0_1234567"], parentPID: 1, terminal: false, inAppBundle: true))
        // `blackice` typed in a terminal: a shell is the parent, and the terminal is there.
        #expect(!MenuLaunch.opensAsApp(arguments: [], parentPID: 4242, terminal: true, inAppBundle: true))
        #expect(!MenuLaunch.opensAsApp(arguments: [], parentPID: 1, terminal: true, inAppBundle: true))
        #expect(!MenuLaunch.opensAsApp(arguments: [], parentPID: 4242, terminal: false, inAppBundle: true))
        // The daemon's LaunchAgent and hooks pass a command; a build outside the app never opens it.
        #expect(!MenuLaunch.opensAsApp(arguments: ["daemon"], parentPID: 1, terminal: false, inAppBundle: true))
        #expect(!MenuLaunch.opensAsApp(arguments: ["menu"], parentPID: 1, terminal: false, inAppBundle: true))
        #expect(!MenuLaunch.opensAsApp(arguments: [], parentPID: 1, terminal: false, inAppBundle: false))
    }

    @Test func oneMenuAtATime() throws {
        let directory = try makePrivateDirectory()
        defer { removeTree(directory) }
        let url = directory.appendingPathComponent("blackice-menu.lock")
        var first = try MenuInstanceLock(url: url)
        #expect(first != nil)
        #expect(try MenuInstanceLock(url: url) == nil)
        #expect(MenuInstanceLock.isHeld(url: url))
        first = nil
        #expect(!MenuInstanceLock.isHeld(url: url))
        #expect(try MenuInstanceLock(url: url) != nil)

        let link = directory.appendingPathComponent("link.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: FileSafetyError.self) { try MenuInstanceLock(url: link) }
    }
}

struct MenuTextTests {
    @Test func whatOthersChoseIsCleaned() {
        #expect(MenuText.clean("evil\u{202E}moc.elgoog", limit: 64) == "evilmoc.elgoog")
        #expect(MenuText.clean("a\u{2066}b\u{2069}c\u{200B}d\u{FEFF}", limit: 64) == "abcd")
        #expect(MenuText.clean("two\nlines\tand\r\nmore", limit: 64) == "two lines and more")
        #expect(MenuText.clean("  spaced   out  ", limit: 64) == "spaced out")
        #expect(MenuText.clean("\u{1B}[31mred", limit: 64) == "[31mred")
        #expect(MenuText.clean("e\u{301}\u{301}\u{301}\u{301}x", limit: 64) == "e\u{301}\u{301}x")
        #expect(MenuText.clean("private\u{E000}use", limit: 64) == "privateuse")
        #expect(MenuText.clean(String(repeating: "a", count: 40), limit: 10) == "aaaaaaaaa…")
        #expect(MenuText.host("login.example.com." + String(repeating: "x", count: 80) + ".evil.example").hasSuffix(".evil.example"))
        #expect(MenuText.host(String(repeating: "a", count: 100)).count == MenuText.hostLimit)
        #expect(MenuText.host("example.com") == "example.com")
    }

    @Test func appsAreNamedByTheirBundle() {
        let identity = safari.identity
        #expect(MenuText.appName(path: "/Applications/Safari.app/Contents/MacOS/Safari", identity: identity) == "Safari")
        #expect(MenuText.appName(path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
                                 identity: vscode.identity) == "Visual Studio Code")
        #expect(MenuText.appName(path: "/Library/SystemExtensions/0A1B/io.tailscale.ipn.macsys.network-extension.systemextension/" +
                                 "Contents/MacOS/io.tailscale.ipn.macsys.network-extension", identity: nil)
                == "io.tailscale.ipn.macsys.network-extension")
        #expect(MenuText.appName(path: "/usr/bin/curl", identity: nil) == "curl")
        #expect(MenuText.appName(path: nil, identity: .signed(SigningIdentity(signingID: "com.apple.curl", teamID: nil))) == "com.apple.curl")
        #expect(MenuText.appName(path: nil, identity: .cdhash(String(repeating: "a", count: 40))) == "ad hoc code")
        #expect(MenuText.appName(path: "/tmp/\u{202E}gpj.app/x", identity: nil) == "gpj")
    }
}

struct MenuPresentationTests {
    @Test func theStatusItemIsFullOnlyWhileFiltering() throws {
        let ask = try saved(.ask), block = try saved(.blockAll), accept = try saved(.acceptAll)
        let waiting = MenuSnapshot(filter: .on(saved: ask, hooks: 1), pending: answering(ask, [summary(), summary("ev-0a1b2c3e")]))
        #expect(MenuPresentation.statusItem(waiting) == StatusItemLook(dimmed: false, count: "2", toolTip: "blackice: Ask mode, 2 waiting"))
        #expect(MenuPresentation.statusItem(MenuSnapshot(filter: .on(saved: block, hooks: 0), pending: answering(block))) ==
                StatusItemLook(dimmed: false, count: "", toolTip: "blackice: Block all"))
        #expect(MenuPresentation.statusItem(MenuSnapshot(filter: .on(saved: accept, hooks: 0), pending: answering(accept))).dimmed)
        // The mode the filter reports counts, not the one saved.
        #expect(MenuPresentation.statusItem(MenuSnapshot(filter: .on(saved: ask, hooks: 0), pending: answering(accept))).dimmed)
        #expect(!MenuPresentation.statusItem(MenuSnapshot(filter: .on(saved: accept, hooks: 0), pending: answering(block))).dimmed)
        // A filter that holds no configuration lets nothing new through.
        let empty = PendingReply(events: [], approvals: [])
        #expect(!MenuPresentation.statusItem(MenuSnapshot(filter: .on(saved: accept, hooks: 0), pending: empty)).dimmed)
        let unreachable = MenuSnapshot(filter: .on(saved: ask, hooks: 1))
        #expect(MenuPresentation.statusItem(unreachable) == StatusItemLook(dimmed: true, count: "", toolTip: "blackice: Not reachable"))
        for filter in [MenuSnapshot.Filter.off, .unsignedBuild, .foreign, .unreadable, .unknown] {
            #expect(MenuPresentation.statusItem(MenuSnapshot(filter: filter)).dimmed)
        }
    }

    @Test func theHeaderSaysTheModeOrWhy() throws {
        func header(_ snapshot: MenuSnapshot) -> [String] {
            let (title, notes) = MenuPresentation.header(snapshot)
            return [title] + notes
        }
        let ask = try saved(.ask), block = try saved(.blockAll), accept = try saved(.acceptAll)
        #expect(header(MenuSnapshot(filter: .on(saved: ask, hooks: 1), pending: answering(ask))) == ["Ask mode"])
        #expect(header(MenuSnapshot(filter: .on(saved: block, hooks: 1), pending: answering(block))) == ["Block all"])
        #expect(header(MenuSnapshot(filter: .on(saved: accept, hooks: 1), pending: answering(accept))) == ["Accept all"])
        #expect(header(MenuSnapshot(filter: .off)) == ["Off", "Turn it on with: blackice start"])
        #expect(header(MenuSnapshot(filter: .unsignedBuild)) == ["Not reachable", "This build is not the signed Blackice.app"])
        #expect(header(MenuSnapshot(filter: .on(saved: block, hooks: 0))) ==
                ["Not reachable", "Set to block all, but the filter does not answer", "If blackice was just upgraded, restart the Mac"])
        let upgrade = try #require(UnfinishedUpgrade(app: "15", running: ["14"]))
        #expect(header(MenuSnapshot(filter: .on(saved: ask, hooks: 0), upgrade: upgrade)) ==
                ["Upgrade not finished: run blackice start", "The filter is still build 14; this app is build 15"])
        #expect(header(MenuSnapshot(filter: .on(saved: ask, hooks: 0), pending: answering(ask), upgrade: upgrade)) == ["Ask mode"])
        // As blackice status: a filter that kept another configuration, or holds none.
        #expect(header(MenuSnapshot(filter: .on(saved: try saved(.blockAll, generation: 4), hooks: 0), pending: answering(ask))) ==
                ["Ask mode", "The filter did not take the saved settings (block all)", "Load them again with: blackice start"])
        #expect(header(MenuSnapshot(filter: .on(saved: try saved(.ask, generation: 4), hooks: 0), pending: answering(ask))) ==
                ["Ask mode", "The filter did not take the saved settings", "Load them again with: blackice start"])
        #expect(header(MenuSnapshot(filter: .on(saved: ask, hooks: 0), pending: PendingReply(events: [], approvals: []))) ==
                ["No configuration", "The filter lets no new connection through", "Load yours again with: blackice start"])
    }

    @Test func waitingConnectionsCountDownAndOfferTheHandAnswers() throws {
        let readAt = Date(timeIntervalSince1970: 1_000_000)
        let ask = try saved(.ask)
        let pending = answering(ask, [summary(secondsLeft: 40, connections: 2),
                                      summary("ev-0a1b2c3e", app: vscode, path: nil, host: "update.code.visualstudio.com",
                                              secondsLeft: 3, connections: 0)])
        let snapshot = MenuSnapshot(filter: .on(saved: ask, hooks: 1), pending: pending, daemonRunning: true, readAt: readAt)
        let entries = MenuPresentation.menu(snapshot, context, now: readAt.addingTimeInterval(5))
        #expect(titles(entries) == [
            "Ask mode", "blackice 0.3.2 (build 15)",
            "Waiting", "Safari → example.com:443", "com.microsoft.VSCode → update.code.visualstudio.com:443",
            "Mode", "Hooks: 1, run by the daemon", "Stop Filtering…",
            "Open blackice.toml", "Show Event Log in Finder", "Documentation",
            "Open at Login", "Quit Menu (filtering continues)",
        ])
        #expect(entries.first { $0.key == "stop" }.map { $0.kind == .command(.stop) && $0.enabled } == true)
        let waiting = entries.filter { $0.key.hasPrefix("waiting.ev-") }
        #expect(waiting.map(\.detail) == ["35 s left", "0 s left"])
        #expect(waiting.allSatisfy { $0.enabled })
        guard case .waiting(let first) = waiting[0].kind, case .waiting(let second) = waiting[1].kind else {
            Issue.record("not waiting entries")
            return
        }
        #expect(first.lines == ["apple/com.apple.Safari", "2 connections wait", "example.com:443 (203.0.113.7)",
                                "/Applications/Safari.app/Contents/MacOS/Safari"])
        #expect(second.lines[1] == "No connection left; an approval covers the next try")
        // The same requests as blackice approve --for 10m / 1h and deny: Touch ID, no token.
        #expect(MenuAnswer.all.map(\.title) == ["Allow for 10 Minutes", "Allow for 1 Hour", "Deny"])
        let requests = MenuAnswer.all.map { $0.request(for: first) }
        #expect(requests.map(\.kind) == [.approve, .approve, .deny])
        #expect(requests.map(\.seconds) == [600, 3600, nil])
        #expect(requests.allSatisfy { $0.authorization == .touchID && $0.host == "example.com" && $0.identity == safari.identity })
        for request in requests { try request.validate(now: Date()) }
        // The mode submenu has a check mark on ask and can be used.
        #expect(entries.contains { $0.kind == .modes(current: .ask) && $0.enabled })
    }

    @Test func manyWaitingConnectionsAreCut() throws {
        let ask = try saved(.ask), block = try saved(.blockAll)
        let events = (0..<20).map { summary(String(format: "ev-%08x", $0), host: "h\($0).example.com") }
        let entries = MenuPresentation.menu(MenuSnapshot(filter: .on(saved: ask, hooks: 0), pending: answering(ask, events)), context)
        #expect(entries.filter { $0.key.hasPrefix("waiting.ev-") }.count == MenuPresentation.waitingLimit)
        #expect(entries.contains { $0.title == "8 more: blackice pending" })
        let quiet = MenuPresentation.menu(MenuSnapshot(filter: .on(saved: ask, hooks: 0), pending: answering(ask)), context)
        #expect(quiet.contains { $0.title == "Nothing waits for an answer" })
        let blocking = MenuPresentation.menu(MenuSnapshot(filter: .on(saved: block, hooks: 0), pending: answering(block)), context)
        #expect(!blocking.contains { $0.key == "waiting.section" })
    }

    /// A connection with no name waits under its address, written as blackice pending writes it.
    @Test func aConnectionWithNoNameWaitsUnderItsAddress() throws {
        let ask = try saved(.ask)
        let ssh = AppReference(signingID: "com.apple.ssh", teamID: nil, cdhash: nil)
        let events = [PendingSummary(id: "ev-0a1b2c3d", app: ssh, path: "/usr/bin/ssh", host: "100.66.32.75", ip: "100.66.32.75",
                                     port: 22, secondsLeft: 40, connections: 1),
                      PendingSummary(id: "ev-0a1b2c3e", app: ssh, path: "/usr/bin/ssh", host: "fd7a:115c:a1e0::1",
                                     ip: "fd7a:115c:a1e0::1", port: 22, secondsLeft: 40, connections: 1)]
        let entries = MenuPresentation.menu(MenuSnapshot(filter: .on(saved: ask, hooks: 0), pending: answering(ask, events)), context)
        let waiting = entries.filter { $0.key.hasPrefix("waiting.ev-") }
        #expect(waiting.map(\.title) == ["ssh → 100.66.32.75:22", "ssh → [fd7a:115c:a1e0::1]:22"])
        guard case .waiting(let first) = waiting[0].kind, case .waiting(let second) = waiting[1].kind else {
            Issue.record("not waiting entries")
            return
        }
        #expect(first.lines[2] == "100.66.32.75:22 (no host name)")
        #expect(second.lines[2] == "[fd7a:115c:a1e0::1]:22 (no host name)")
        // The answer names the address, as blackice approve --host 100.66.32.75 does.
        let request = MenuAnswer.all[0].request(for: first)
        #expect(request.host == "100.66.32.75")
        try request.validate(now: Date())
    }

    @Test func anUnsignedBuildShowsWhatItCannotDo() {
        let unavailable = MenuContext(version: nil, login: .unavailable("Only Blackice.app opens at login, not this build"),
                                      configExists: false, logExists: false)
        let entries = MenuPresentation.menu(MenuSnapshot(filter: .unsignedBuild), unavailable)
        #expect(titles(entries) == [
            "Not reachable", "This build is not the signed Blackice.app", "blackice, a build outside Blackice.app",
            "Mode", "Open blackice.toml", "Show Event Log in Finder", "Documentation",
            "Open at Login", "Only Blackice.app opens at login, not this build", "Quit Menu (filtering continues)",
        ])
        let enabled = entries.filter(\.enabled).map(\.title)
        #expect(enabled == ["Documentation", "Quit Menu (filtering continues)"])
    }

    @Test func recentDecisionsAndTheOtherLines() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var withRecent = context
        withRecent.recent = [
            RecentDecision(verdict: .approved, app: "Safari", host: "example.com", date: now.addingTimeInterval(-30), by: .hand),
            RecentDecision(verdict: .denied, app: "curl", host: "pastebin.com", date: now.addingTimeInterval(-300), by: .hook),
            RecentDecision(verdict: .approved, app: "git", host: "github.com", date: now.addingTimeInterval(-400)),
            RecentDecision(verdict: .timedOut, app: "curl", host: "example.org", date: now.addingTimeInterval(-7200)),
            RecentDecision(verdict: .cancelled, app: "nscurl", host: "example.net", date: nil),
        ]
        withRecent.hookRefused = now.addingTimeInterval(-600)
        withRecent.login = .on
        let block = try saved(.blockAll)
        let entries = MenuPresentation.menu(MenuSnapshot(filter: .on(saved: block, hooks: 2), daemonRunning: false), withRecent, now: now)
        let recent = entries.filter { $0.kind == .recent }
        #expect(recent.map(\.title) == ["Allowed Safari → example.com", "Denied curl → pastebin.com", "Allowed git → github.com",
                                        "Dropped curl → example.org", "Dropped nscurl → example.net"])
        #expect(recent.map(\.detail) == ["by hand, just now", "by a hook, 5 min ago", "6 min ago", "no answer in time, 2 h ago",
                                         "settings changed"])
        #expect(entries.contains { $0.title == "Hooks: 2, but the daemon is not running" })
        #expect(entries.contains { $0.title == "Start it with: blackice agent install" })
        #expect(entries.contains { $0.title == "A hook did not run: its signature did not match" && $0.detail == "10 min ago" })
        #expect(entries.contains { $0.key == "login" && $0.checked && $0.enabled })
        // A filter that does not answer cannot take a new mode, which `blackice mode` waits for.
        #expect(entries.contains { $0.kind == .modes(current: .blockAll) && !$0.enabled })
        #expect(MenuPresentation.hooksLine(hooks: 0, daemonRunning: true).0 == "Hooks: none, daemon running")
        #expect(MenuPresentation.hooksLine(hooks: 1, daemonRunning: nil).0 == "Hooks: 1")
        // A refused hook stays in the menu for an hour.
        withRecent.hookRefused = now.addingTimeInterval(-MenuPresentation.refusedHookWindow)
        #expect(!MenuPresentation.menu(MenuSnapshot(filter: .on(saved: block, hooks: 2)), withRecent, now: now)
            .contains { $0.key == "hooks.refused" })
        // An off filter has no mode to switch from.
        let off = MenuPresentation.menu(MenuSnapshot(filter: .off), context)
        #expect(off.contains { $0.kind == .modes(current: nil) && !$0.enabled })
        #expect(!off.contains { $0.key == "hooks" })
    }

    @Test func keysStayWhileTheLinesMeanTheSame() throws {
        let readAt = Date()
        let ask = try saved(.ask)
        let snapshot = MenuSnapshot(filter: .on(saved: ask, hooks: 1), pending: answering(ask, [summary()]), readAt: readAt)
        let now = MenuPresentation.menu(snapshot, context, now: readAt)
        let later = MenuPresentation.menu(snapshot, context, now: readAt.addingTimeInterval(3))
        #expect(now.map(\.key) == later.map(\.key))
        #expect(now != later)
        #expect(Set(now.map(\.key)).count == now.count)
    }
}

struct MenuStateTests {
    @Test func theSavedFilterReadsAsStatusDoes() throws {
        let configuration = try ProviderConfiguration(generation: 3, mode: .ask, configText: "mode = \"ask\"\n")
        #expect(MenuSnapshot.Filter(SavedFilter(providerBundleID: nil, enabled: false, configuration: nil)) == .off)
        #expect(MenuSnapshot.Filter(SavedFilter(providerBundleID: BlackiceIdentifiers.filter, enabled: false,
                                                configuration: configuration)) == .off)
        #expect(MenuSnapshot.Filter(SavedFilter(providerBundleID: "com.example.vpn.filter", enabled: true,
                                                configuration: nil)) == .foreign)
        #expect(MenuSnapshot.Filter(SavedFilter(providerBundleID: BlackiceIdentifiers.filter, enabled: true,
                                                configuration: nil)) == .unreadable)
        #expect(MenuSnapshot.Filter(SavedFilter(providerBundleID: BlackiceIdentifiers.filter, enabled: true,
                                                configuration: configuration)) ==
                .on(saved: ActiveConfiguration(configuration), hooks: 0))
    }

    @Test func theModeIsTheOneTheFilterDecidesIn() throws {
        let ask = try saved(.ask), block = try saved(.blockAll, generation: 4)
        #expect(MenuSnapshot(filter: .on(saved: block, hooks: 0), pending: answering(ask)).mode == .ask)
        #expect(MenuSnapshot(filter: .on(saved: block, hooks: 0)).mode == .blockAll)
        #expect(MenuSnapshot(filter: .on(saved: block, hooks: 0), pending: PendingReply(events: [], approvals: [])).mode == nil)
        #expect(MenuSnapshot(filter: .off, pending: answering(ask)).mode == nil)
    }

    @Test func onlyTheSignedAppInApplicationsOpensAtLogin() {
        #expect(LoginItemCheck.unavailableReason(bundlePath: "/Applications/Blackice.app", bundleID: BlackiceIdentifiers.host,
                                                 signed: true) == nil)
        #expect(LoginItemCheck.unavailableReason(bundlePath: "/Users/me/Downloads/Blackice.app", bundleID: BlackiceIdentifiers.host,
                                                 signed: true) == "Only for Blackice.app in /Applications")
        #expect(LoginItemCheck.unavailableReason(bundlePath: "/Applications/Blackice.app", bundleID: BlackiceIdentifiers.host,
                                                 signed: false) == "Only for Blackice.app signed with its Developer ID")
        #expect(LoginItemCheck.unavailableReason(bundlePath: "/Users/me/blackice/macos/.build/debug", bundleID: nil,
                                                 signed: false) == "Only Blackice.app opens at login, not this build")
    }

    @Test func aCancelledTouchIDSaysNothing() {
        #expect(SystemAdapter.result(0, []) == .done)
        #expect(SystemAdapter.result(ExitCode.noPermission, [SystemAdapter.cancelledLine]) == .cancelled)
        #expect(SystemAdapter.result(ExitCode.noPermission, ["blackice approve: the event is gone"]) ==
                .failed("blackice approve: the event is gone"))
        #expect(SystemAdapter.result(ExitCode.unavailable, []) == .failed("blackice stopped with status 69."))
        // A mode the filter did not take: the lines `blackice mode` prints, exit 70.
        let saved = try? ProviderConfiguration(generation: 5, mode: .blockAll, configText: "mode = \"ask\"\n")
        let lines = saved.map { CLI.notActiveLines($0, .other(nil)) } ?? []
        #expect(SystemAdapter.result(CLI.activationStatus(.other(nil)), lines) == .failed(lines.joined(separator: "\n")))
    }

    @Test func theMarkIsTheLogosPath() {
        #expect(Mark.corners.count == 10)
        let (size, corners) = Mark.layout(height: 18, markHeight: 16)
        #expect(size == CGSize(width: 16, height: 18))
        let ys = corners.map(\.y), xs = corners.map(\.x)
        #expect(abs(ys.min()! - 1) < 0.001 && abs(ys.max()! - 17) < 0.001)
        #expect(abs((xs.max()! + xs.min()!) / 2 - 8) < 0.001)
        // The channel ends at the center of the mark.
        #expect(abs(corners[6].x - (xs.max()! + xs.min()!) / 2) < 0.001)
        #expect(Mark.image().isTemplate)
    }
}

struct RecentDecisionsTests {
    @Test func theLastVerdictsComeWithTheirEvents() throws {
        let directory = try makePrivateDirectory()
        defer { removeTree(directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try log.append(.eventReceived(testEvent(host: "example.com", id: "ev-00000001")), at: start)
        try log.append(.eventReceived(testEvent(host: "pastebin.com", id: "ev-00000002", app: "com.example.other")), at: start)
        try log.append(.verdict(eventID: "ev-00000001", .approved), at: start.addingTimeInterval(5))
        try log.append(.verdict(eventID: "ev-00000002", .denied), at: start.addingTimeInterval(9))
        try log.append(.verdict(eventID: "ev-0000ffff", .timedOut), at: start.addingTimeInterval(10))
        let recent = RecentDecisions(url: url)
        #expect(recent.latest(limit: 5) == EventLogSummary(decisions: [
            RecentDecision(verdict: .denied, app: "Tool", host: "pastebin.com", date: start.addingTimeInterval(9), by: .hand),
            RecentDecision(verdict: .approved, app: "Tool", host: "example.com", date: start.addingTimeInterval(5), by: .hand),
        ]))
        #expect(recent.latest(limit: 1).decisions.count == 1)

        // A line someone else wrote into the log is cleaned like the rest; junk is skipped.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let forged = #"{"type":"event_received","event":"ev-00000003","app_path":"/x/Evil‮ppa.app/y","host":"a‮b.example","ip":"203.0.113.9","port":443}"#
        try handle.write(contentsOf: Data((forged + "\nnot json\n" + #"{"type":"verdict","event":"ev-00000003","verdict":"approved","ts":"2027-01-15T08:00:00.123Z"}"# + "\n").utf8))
        try handle.close()
        let latest = recent.latest(limit: 1).decisions
        #expect(latest.first?.app == "Evilppa" && latest.first?.host == "ab.example" && latest.first?.date != nil)
    }

    /// A hook's answer that the extension took, a person's, and the last refused hook, from the
    /// records the daemon writes.
    @Test func whoAnswered() throws {
        let directory = try makePrivateDirectory()
        defer { removeTree(directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let log = try EventLog(url: url)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func finished(_ id: String, _ outcome: HookResult.Outcome) throws {
            try log.append(.hookFinished(eventID: id, HookResult(hookLine: 7, outcome: outcome, stderr: "", stderrTruncated: false,
                                                                 duration: 1)), at: start)
        }
        // A hook answered and the extension took it.
        try log.append(.eventReceived(testEvent(host: "a.example", id: "ev-00000001")), at: start)
        try log.append(.hookStarted(eventID: "ev-00000001", hookLine: 7, pid: 42), at: start)
        try finished("ev-00000001", .exited(status: 0))
        try log.append(.hookAnswered(eventID: "ev-00000001", hookLine: 7, .approve(seconds: 600)), at: start)
        try log.append(.verdict(eventID: "ev-00000001", .approved), at: start.addingTimeInterval(1))
        // A person denied first, so the hook's late answer was refused.
        try log.append(.eventReceived(testEvent(host: "b.example", id: "ev-00000002")), at: start)
        try log.append(.hookStarted(eventID: "ev-00000002", hookLine: 7, pid: 43), at: start)
        try log.append(.verdict(eventID: "ev-00000002", .denied), at: start.addingTimeInterval(2))
        try finished("ev-00000002", .exited(status: 0))
        try log.append(.hookAnswered(eventID: "ev-00000002", hookLine: 7, .approve(seconds: 600)), at: start)
        try log.append(.answerRefused(eventID: "ev-00000002", hookLine: 7, reason: "token_spent"), at: start.addingTimeInterval(3))
        // The hook gave no answer and a person approved.
        try log.append(.eventReceived(testEvent(host: "c.example", id: "ev-00000003")), at: start)
        try log.append(.hookStarted(eventID: "ev-00000003", hookLine: 7, pid: 44), at: start)
        try finished("ev-00000003", .exited(status: 1))
        try log.append(.hookNoAnswer(eventID: "ev-00000003", hookLine: 7, .exitStatus(1)), at: start)
        try log.append(.verdict(eventID: "ev-00000003", .approved), at: start.addingTimeInterval(4))
        // A person approved while the hook still ran: not known yet.
        try log.append(.eventReceived(testEvent(host: "d.example", id: "ev-00000004")), at: start)
        try log.append(.hookStarted(eventID: "ev-00000004", hookLine: 7, pid: 45), at: start)
        try log.append(.verdict(eventID: "ev-00000004", .approved), at: start.addingTimeInterval(5))
        // The hook program's signature did not match, so it never ran.
        try log.append(.eventReceived(testEvent(host: "e.example", id: "ev-00000005")), at: start)
        try finished("ev-00000005", .refused(found: "invalid_signature"))
        try log.append(.verdict(eventID: "ev-00000005", .timedOut), at: start.addingTimeInterval(30))
        // One hook's answer closes every event of the same app and host, while their own hooks wait.
        let later = start.addingTimeInterval(60)
        for id in ["ev-00000006", "ev-00000007"] {
            try log.append(.eventReceived(testEvent(host: "f.example", id: id)), at: later)
            try log.append(.hookQueued(eventID: id, hookLine: 7, waiting: 1), at: later)
        }
        try log.append(.hookAnswered(eventID: "ev-00000006", hookLine: 7, .deny), at: later)
        try log.append(.verdict(eventID: "ev-00000006", .denied), at: later)
        try log.append(.verdict(eventID: "ev-00000007", .denied), at: later.addingTimeInterval(0.1))
        let summary = RecentDecisions(url: url).latest(limit: 10)
        #expect(summary.decisions.map(\.host) == ["f.example", "f.example", "e.example", "d.example", "c.example", "b.example",
                                                  "a.example"])
        #expect(summary.decisions.map(\.by) == [.hook, .hook, nil, nil, .hand, .hand, .hook])
        #expect(summary.hookRefused == start)

        // A log from before hooks answered on their output: the hook ran, and nothing says more.
        let old = #"{"type":"event_received","event":"ev-00000008","app_signing_id":"com.apple.curl","host":"pypi.org","ip":"203.0.113.1","port":443}"# + "\n" +
            #"{"type":"hook_started","event":"ev-00000008","hook_line":3,"pid":7}"# + "\n" +
            #"{"type":"hook_exited","event":"ev-00000008","hook_line":3,"status":0}"# + "\n" +
            #"{"type":"verdict","event":"ev-00000008","verdict":"approved"}"#
        #expect(RecentDecisions.parse(Data(old.utf8), partialFirstLine: false, limit: 5).decisions.map(\.by) == [nil])
    }

    @Test func aStretchThatStartsMidRecordSkipsThatPiece() {
        let text = #"ype":"verdict","event":"ev-00000001","verdict":"approved"}"# + "\n" +
            #"{"type":"event_received","event":"ev-00000002","app_signing_id":"com.apple.curl","host":"pypi.org","ip":"203.0.113.1","port":443}"# + "\n" +
            #"{"type":"verdict","event":"ev-00000002","verdict":"timed_out"}"#
        let parsed = RecentDecisions.parse(Data(text.utf8), partialFirstLine: true, limit: 5)
        #expect(parsed == EventLogSummary(decisions: [RecentDecision(verdict: .timedOut, app: "com.apple.curl", host: "pypi.org",
                                                                     date: nil)]))
        #expect(RecentDecisions(url: URL(fileURLWithPath: "/nonexistent/events.jsonl")).latest(limit: 5) == EventLogSummary())
    }
}

/// Stands in for the menu bar app in the CLI.
private final class FakeMenuBar: MenuBarControlling {
    var canOffer: Bool
    var calls: [String] = []

    init(canOffer: Bool) { self.canOffer = canOffer }

    func run(output: SystemOutput) -> Int32 { calls.append("run"); return 0 }

    func setOpenAtLogin(_ on: Bool, output: SystemOutput) -> Int32 {
        calls.append("login \(on)")
        output.stdout("✓ blackice opens in the menu bar at each login.")
        return 0
    }
}

private final class StartOnly: SystemControlling {
    func start(configText: String, output: SystemOutput) -> Int32 { 0 }
    func stop(output: SystemOutput) -> Int32 { 0 }
    func status(output: SystemOutput) -> Int32 { 0 }
    func setMode(_ mode: Mode, output: SystemOutput) -> Int32 { 0 }
    func pending(output: SystemOutput) -> Int32 { 0 }
    func answer(_ request: AnswerRequest, output: SystemOutput) -> Int32 { 0 }
    func runDaemon(output: SystemOutput) -> Int32 { 0 }
    func installAgent(output: SystemOutput) -> Int32 { 0 }
    func uninstallAgent(output: SystemOutput) -> Int32 { 0 }
}

struct MenuCommandTests {
    @Test func parsing() throws {
        #expect(try CLI.parse(["menu"]) == .menu(.run))
        #expect(try CLI.parse(["menu", "--login", "on"]) == .menu(.login(true)))
        #expect(try CLI.parse(["menu", "--login=off"]) == .menu(.login(false)))
        for bad in [["menu", "--login", "yes"], ["menu", "now"], ["menu", "--login"], ["menu", "--quit"]] {
            #expect(throws: UsageError.self) { try CLI.parse(bad) }
        }
        #expect(CLI.usage.contains("menu [--login on|off]"))
    }

    @Test func theCommandReachesTheMenuBar() {
        let menuBar = FakeMenuBar(canOffer: false)
        #expect(CLI.run(["menu"], stdout: { _ in }, stderr: { _ in }, menuBar: menuBar) == 0)
        #expect(CLI.run(["menu", "--login", "off"], stdout: { _ in }, stderr: { _ in }, menuBar: menuBar) == 0)
        #expect(menuBar.calls == ["run", "login false"])
        let err = Recorder<String>()
        #expect(CLI.run(["menu"], stdout: { _ in }, stderr: { err.append($0) }) == ExitCode.unavailable)
        #expect(err.items == ["This blackice has no menu bar app."])
    }

    /// The first start offers the menu bar at its end, once the filter is on.
    @Test func theFirstStartOffersIt() {
        func firstStart(_ answers: [String], canOffer: Bool) -> (status: Int32, prompts: [String], stdout: [String], calls: [String]) {
            var script = answers
            var prompts: [String] = []
            var files: [String: Data] = [:]
            let out = Recorder<String>()
            let menuBar = FakeMenuBar(canOffer: canOffer)
            let interaction = Interaction(
                ask: { prompts.append($0); return script.isEmpty ? nil : script.removeFirst() },
                createFile: { path, data in files[path] = data }, identify: { _ in nil },
                fileExists: { files[$0] != nil }, home: NSHomeDirectory(), version: nil)
            let status = CLI.run(["start"], stdout: { out.append($0) }, stderr: { _ in }, readFile: { path in
                guard let data = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
                return data
            }, system: StartOnly(), interaction: interaction, menuBar: menuBar)
            return (status, prompts, out.items, menuBar.calls)
        }
        let yes = firstStart(["", "y"], canOffer: true)
        #expect(yes.status == 0 && yes.calls == ["login true"])
        #expect(yes.prompts == ["  Mode [1]: ", "Show blackice in the menu bar and open it at login? [Y/n]: "])
        #expect(yes.stdout.last == "✓ blackice opens in the menu bar at each login.")
        let enter = firstStart(["", "maybe", ""], canOffer: true)
        #expect(enter.calls == ["login true"] && enter.stdout.contains("  Type y or n."))
        let no = firstStart(["", "n"], canOffer: true)
        #expect(no.calls.isEmpty && no.stdout.last == "  Later, with: blackice menu --login on")
        let cannot = firstStart([""], canOffer: false)
        #expect(cannot.calls.isEmpty && cannot.prompts == ["  Mode [1]: "])
    }
}
