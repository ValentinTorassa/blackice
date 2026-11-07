// The AppKit side of the menu bar app: the status item, its menu, and the actions. What the menu
// says comes from MenuPresentation; what it reads and changes goes through SystemAdapter.
import AppKit
import UniformTypeIdentifiers
import BlackiceCLI
import BlackiceCore

/// The menu bar app, as `blackice menu` and the first start reach it.
public struct MenuBar: MenuBarControlling {
    public init() {}

    /// `blackice menu`: runs in this process until it quits.
    public func run(output: SystemOutput) -> Int32 {
        MainActor.assumeIsolated { MenuApp.run(output: output) }
    }

    /// Opened as an app (`MenuLaunch.opensAsApp`), where nobody reads stdout or stderr.
    public static func runAsApp() -> Int32 {
        MainActor.assumeIsolated { MenuApp.run(output: nil) }
    }

    public var canOffer: Bool { LoginItem.state == .off }

    /// With no menu bar app running, LaunchServices opens this build's. When one from another build
    /// holds the lock, SIGTERM ends it (it has nothing to save, and the filter goes on) and this
    /// build's opens. Menus from 0.4.1 on also do this themselves; one from 0.4.0 cannot tell that
    /// the app under it changed.
    public func openAfterStart(output: SystemOutput) {
        guard LoginItem.unavailableReason == nil, let url = try? MenuInstanceLock.defaultURL() else { return }
        guard MenuInstanceLock.isHeld(url: url) else {
            if case .failed(let why) = MenuApp.openNow() {
                output.stderr("blackice did not open in the menu bar (\(why)). Open Blackice.app to start it.")
            }
            return
        }
        guard MenuUpgrade.outdated(recorded: MenuInstanceLock.recordedBuild(url: url),
                                   own: Bundle.main.infoDictionary?["CFBundleVersion"] as? String) else { return }
        let menus = NSRunningApplication.runningApplications(withBundleIdentifier: BlackiceIdentifiers.host)
            .filter { $0.processIdentifier != getpid() && $0.activationPolicy == .accessory }
        guard !menus.isEmpty else { return }
        menus.forEach { kill($0.processIdentifier, SIGTERM) }
        for _ in 0..<25 where MenuInstanceLock.isHeld(url: url) { usleep(200_000) }
        guard !MenuInstanceLock.isHeld(url: url) else {
            output.stderr("The menu bar app runs the build from before the upgrade: quit it from its menu, then open Blackice.app.")
            return
        }
        switch MenuApp.openNow() {
        case .opened, .alreadyRunning:
            output.stdout(Style.done("The menu bar app runs this build now"))
        case .failed(let why):
            output.stderr("The menu bar app from before the upgrade quit, and this build's did not open (\(why)). Open Blackice.app.")
        }
    }

    /// `blackice menu --login on|off`. On also opens the menu bar app now, through LaunchServices,
    /// so it runs apart from the terminal.
    public func setOpenAtLogin(_ on: Bool, output: SystemOutput) -> Int32 {
        guard LoginItem.unavailableReason == nil else {
            output.stderr(UnsignedSystem.refusal("menu --login"))
            return ExitCode.unavailable
        }
        let before = LoginItem.state
        if !on, before == .off {
            output.stdout("blackice does not open at login.")
            return ExitCode.success
        }
        do {
            if !on || before == .off { try LoginItem.set(on) }
        } catch {
            output.stderr("macOS did not \(on ? "add" : "remove") the login item: \(error.localizedDescription)")
            return ExitCode.software
        }
        guard on else {
            output.stdout(Style.done("blackice no longer opens at login; Quit Menu in its menu closes it now"))
            return ExitCode.success
        }
        let needsApproval = LoginItem.state == .needsApproval
        if needsApproval {
            output.stdout("To open it at each login, turn Blackice on in System Settings › General › Login Items.")
            LoginItem.openSettings()
        }
        switch MenuApp.openNow() {
        case .alreadyRunning, .opened:
            output.stdout(Style.done("blackice is in the menu bar" + (needsApproval ? "" : ", and opens there at each login")))
        case .failed(let why):
            if !needsApproval { output.stdout(Style.done("blackice opens in the menu bar at each login")) }
            output.stderr("blackice did not open in the menu bar now (\(why)). Open Blackice.app to start it.")
        }
        return ExitCode.success
    }
}

@MainActor
enum MenuApp {
    /// Takes the single-instance lock and runs the app. A second copy exits at once with status 0.
    static func run(output: SystemOutput?) -> Int32 {
        let lock: MenuInstanceLock
        do {
            guard let taken = try MenuInstanceLock(url: try MenuInstanceLock.defaultURL()) else {
                output?.stdout("blackice is in the menu bar already.")
                return ExitCode.success
            }
            lock = taken
            if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String { lock.record(build: build) }
        } catch {
            output?.stderr("blackice menu: \(error)")
            return ExitCode.software
        }
        // Alerts show what the commands print to stderr: plain words, no terminal colors.
        Style.enabled = false
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = MenuController(lock: lock)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
        return ExitCode.success
    }

    enum OpenResult { case opened, alreadyRunning, failed(String) }

    /// Opens Blackice.app through LaunchServices, which starts it with no arguments as a child of
    /// launchd: the menu bar app, apart from this terminal. A new instance, since this process
    /// runs from the same bundle; the lock keeps it to one.
    nonisolated static func openNow() -> OpenResult {
        if let url = try? MenuInstanceLock.defaultURL(), MenuInstanceLock.isHeld(url: url) { return .alreadyRunning }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        let done = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        // The completion handler runs on a queue of NSWorkspace's, not this thread.
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            failure.message = error?.localizedDescription
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else { return .failed("macOS did not answer in time") }
        return failure.message.map(OpenResult.failed) ?? .opened
    }
}

private final class FailureBox: @unchecked Sendable {
    var message: String?
}

/// What an Allow or Deny item stands for.
private struct AnswerChoice {
    let answer: MenuAnswer
    let event: WaitingEvent
}

@MainActor
final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// How often the status item reads blackice's state, over XPC, while the menu is closed.
    static let refreshInterval: TimeInterval = 5
    /// How often macOS is asked which build of the extension runs, while the extension does not
    /// answer.
    static let upgradeCheckInterval: TimeInterval = 60

    private let lock: MenuInstanceLock
    /// The build this process started from: Bundle reads Info.plist once.
    private let ownBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    /// Checks in a row that found no Blackice.app on disk.
    private var missingChecks = 0
    private let system = SystemAdapter()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var snapshot = MenuSnapshot(filter: .unknown)
    private var look: StatusItemLook?
    private var context = MenuContext(version: nil)
    private var shown: [MenuEntry] = []
    private var items: [String: NSMenuItem] = [:]
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var reading = false
    private var busy = false
    /// The last answer to SystemAdapter.unfinishedUpgrade, kept while the extension does not answer.
    private var upgrade: UnfinishedUpgrade?
    private var upgradeCheckedAt: Date?
    private var menuOpen = false
    private var queued: (() -> Void)?
    private let logURL: URL?
    private let recent: RecentDecisions?

    init(lock: MenuInstanceLock) {
        self.lock = lock
        logURL = try? DaemonPaths.eventLog(home: UserAccount.current().homeURL)
        recent = logURL.map(RecentDecisions.init(url:))
        super.init()
    }

    /// "0.3.2 (build 15)"; nil outside Blackice.app.
    static let version: String? = {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        return (info?["CFBundleVersion"] as? String).map { "\(short) (build \($0))" } ?? short
    }()

    // MARK: - The app

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "blackice"
        if let button = item.button {
            button.image = Mark.image()
            button.imagePosition = .imageOnly
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        apply()
        let timer = Timer(timeInterval: Self.refreshInterval, target: self, selector: #selector(tick), userInfo: nil,
                          repeats: true)
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh(full: true)
    }

    /// Opening Blackice.app again (Finder, Spotlight) while it runs shows its menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.button?.performClick(nil)
        return false
    }

    // MARK: - Reading

    @objc private func tick() {
        guard checkInstalledApp() else { return }
        refresh(full: menuOpen)
    }

    /// Blackice.app replaced under this process, by an upgrade, or removed. Each build of the
    /// extension listens on an XPC service of its own, so this one would stay "Not reachable": it
    /// opens the app on disk and quits, or quits when there is none. Never while the menu is open
    /// or Touch ID is up. false once it is going.
    private func checkInstalledApp() -> Bool {
        guard !menuOpen, !busy else { return true }
        let installed = MenuUpgrade.installedBuild(Bundle.main.bundleURL)
        missingChecks = installed == nil ? missingChecks + 1 : 0
        switch MenuUpgrade.decide(running: ownBuild, installed: installed, missing: missingChecks) {
        case .stay:
            return true
        case .quit:
            NSApp.terminate(nil)
            return false
        case .reopen:
            refreshTimer?.invalidate()
            refreshTimer = nil
            lock.release()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            }
            return false
        }
    }

    private func refresh(full: Bool) {
        guard !reading, !busy else { return }
        reading = true
        system.read(full: full) { [weak self] fresh in
            guard let self else { return }
            self.reading = false
            var fresh = fresh
            if !full { fresh.daemonRunning = self.snapshot.daemonRunning }
            let unanswered = fresh.isOn && !fresh.reachable
            if !unanswered {
                self.upgrade = nil
                self.upgradeCheckedAt = nil
            }
            fresh.upgrade = self.upgrade
            self.snapshot = fresh
            self.apply()
            if self.menuOpen { self.render(rebuild: false) }
            if unanswered, self.upgradeCheckedAt.map({ Date().timeIntervalSince($0) >= Self.upgradeCheckInterval }) ?? true {
                self.upgradeCheckedAt = Date()
                // A run loop timer in the default mode: it fires once the menu is closed, and not
                // inside this block from the main queue (see checkUpgrade).
                self.perform(#selector(self.checkUpgrade), with: nil, afterDelay: 0)
            }
            // A build that is not the signed app reads nothing, so there is nothing to poll.
            if fresh.filter == .unsignedBuild {
                self.refreshTimer?.invalidate()
                self.refreshTimer = nil
            }
        }
    }

    /// Asks macOS which build of the extension runs. NESystemControl waits for the answer in a
    /// nested run loop, which drains the main queue only when it is not itself running a block
    /// from it, so this runs from a run loop timer.
    @objc private func checkUpgrade() {
        guard !busy, !menuOpen, snapshot.isOn, !snapshot.reachable else { return }
        let found = system.unfinishedUpgrade()
        // A read that came back meanwhile may have reached the extension.
        guard snapshot.isOn, !snapshot.reachable else { return }
        upgrade = found
        snapshot.upgrade = found
        apply()
    }

    /// The status item, changed only when what it shows changes.
    private func apply() {
        let next = MenuPresentation.statusItem(snapshot)
        guard next != look, let button = statusItem?.button else { return }
        look = next
        button.appearsDisabled = next.dimmed
        button.title = next.count
        button.imagePosition = next.count.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = next.toolTip
        button.setAccessibilityLabel(next.toolTip)
    }

    // MARK: - The menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        let log = recent?.latest(limit: MenuPresentation.recentLimit) ?? EventLogSummary()
        context = MenuContext(version: Self.version, recent: log.decisions, hookRefused: log.hookRefused,
                              hookRefusedForHome: log.hookRefusedForHome)
        render(rebuild: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = true
        refresh(full: true)
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(countdown), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = false
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// The seconds left, while the menu is open.
    @objc private func countdown() { render(rebuild: false) }

    /// Shows the menu for the snapshot. An open menu whose lines are the same as before is
    /// updated in place, so a submenu the person is in stays open.
    private func render(rebuild: Bool) {
        let entries = MenuPresentation.menu(snapshot, context)
        if !rebuild, entries.map(\.key) == shown.map(\.key) {
            for (old, new) in zip(shown, entries) where old != new {
                if let item = items[new.key] { configure(item, new) }
            }
        } else {
            menu.removeAllItems()
            items = [:]
            for entry in entries {
                let item = makeItem(entry)
                menu.addItem(item)
                items[entry.key] = item
            }
        }
        shown = entries
    }

    private func makeItem(_ entry: MenuEntry) -> NSMenuItem {
        switch entry.kind {
        case .separator: return .separator()
        case .section: return .sectionHeader(title: entry.title)
        default: break
        }
        let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        item.target = self
        switch entry.kind {
        case .waiting(let event):
            item.submenu = waitingMenu(event)
        case .modes(let choices):
            item.submenu = modeMenu(choices)
        case .recent(let lines):
            item.submenu = recentMenu(lines)
        case .command(let command):
            item.action = #selector(runCommand(_:))
            item.representedObject = command
            if command == .quit { item.keyEquivalent = "q" }
        default:
            break
        }
        configure(item, entry)
        return item
    }

    private func configure(_ item: NSMenuItem, _ entry: MenuEntry) {
        item.isEnabled = entry.enabled
        item.state = entry.checked ? .on : .off
        if entry.kind == .title {
            item.attributedTitle = NSAttributedString(string: entry.title, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)])
        } else if let detail = entry.detail {
            // One line: the detail ("4m", "8s") after the title, in the secondary color.
            let font = NSFont.menuFont(ofSize: 0)
            let line = NSMutableAttributedString(string: entry.title + "  ", attributes: [.font: font])
            line.append(NSAttributedString(string: detail, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = line
        } else {
            item.attributedTitle = nil
            item.title = entry.title
        }
        switch entry.kind {
        case .waiting(let event):
            guard let submenu = item.submenu, submenu.items.count == event.lines.count + 1 + MenuAnswer.all.count else {
                item.submenu = waitingMenu(event)
                return
            }
            for (index, line) in event.lines.enumerated() { submenu.items[index].title = line }
        case .modes(let choices):
            // Updated in place while the items are the same, so an open submenu stays open.
            let shownItems = item.submenu?.items.filter { !$0.isSeparatorItem } ?? []
            guard shownItems.map(\.title) == choices.map(\.title) else {
                item.submenu = modeMenu(choices)
                return
            }
            for (shownItem, choice) in zip(shownItems, choices) { configure(shownItem, choice) }
        case .recent(let lines):
            item.submenu = recentMenu(lines)
        default:
            break
        }
    }

    /// The last decisions, one line each, to read only.
    private func recentMenu(_ lines: [RecentLine]) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, line) in lines.enumerated() {
            let item = NSMenuItem(title: line.title, action: nil, keyEquivalent: "")
            configure(item, MenuEntry(.note, key: "recent.\(index)", title: line.title, detail: line.detail))
            submenu.addItem(item)
        }
        return submenu
    }

    /// Accept All, the Ask items, Block All, with a separator between modes.
    private func modeMenu(_ choices: [ModeChoice]) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, choice) in choices.enumerated() {
            if index > 0, choices[index - 1].mode != choice.mode { submenu.addItem(.separator()) }
            let item = NSMenuItem(title: choice.title, action: #selector(chooseMode(_:)), keyEquivalent: "")
            item.target = self
            configure(item, choice)
            submenu.addItem(item)
        }
        return submenu
    }

    private func configure(_ item: NSMenuItem, _ choice: ModeChoice) {
        item.representedObject = choice
        item.state = choice.checked ? .on : .off
        item.isEnabled = choice.enabled
        item.subtitle = choice.detail
    }

    /// The event's identity, connections, address and path, then the answers.
    private func waitingMenu(_ event: WaitingEvent) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for line in event.lines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        for answer in MenuAnswer.all {
            let item = NSMenuItem(title: answer.title, action: #selector(chooseAnswer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = AnswerChoice(answer: answer, event: event)
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - Actions

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ModeChoice, !choice.checked else { return }
        afterMenuCloses { [weak self] in
            self?.change(failure: "The mode did not change") { $0.setMode(choice.mode, answerer: choice.answerer) }
        }
    }

    @objc private func chooseAnswer(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AnswerChoice else { return }
        let request = choice.answer.request(for: choice.event)
        afterMenuCloses { [weak self] in
            self?.change(failure: "The answer did not go through") { $0.answer(request) }
        }
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? MenuCommand else { return }
        switch command {
        case .stop: afterMenuCloses { [weak self] in self?.change(failure: "blackice did not stop") { $0.stop() } }
        case .quit: NSApp.terminate(nil)
        }
    }

    /// Runs `work` once the menu has closed, from a run loop timer in the default mode rather
    /// than from the main dispatch queue: Touch ID waits in a nested run loop, which drains the
    /// main queue only when it is not itself running a block from it.
    private func afterMenuCloses(_ work: @escaping () -> Void) {
        queued = work
        perform(#selector(runQueued), with: nil, afterDelay: 0)
    }

    @objc private func runQueued() {
        let work = queued
        queued = nil
        work?()
    }

    /// A mode change or an answer, with Touch ID. Reading pauses meanwhile, since both use the
    /// same NEFilterManager.
    private func change(failure title: String, _ action: (SystemAdapter) -> MenuActionResult) {
        guard !busy else { return }
        busy = true
        let deadline = Date().addingTimeInterval(2)
        while reading, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        // Brings the Touch ID dialog, and an alert, in front of other apps.
        NSApp.activate()
        let result = action(system)
        busy = false
        if case .failed(let message) = result { alert(title, message) }
        refresh(full: true)
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
