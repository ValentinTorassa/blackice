import AppKit
import Foundation

let usage = """
Blackice Probe — URLSession evidence app (not the filter)
  BlackiceProbe URL1 URL2 [URL3]          Sequential HTTPS requests; JSON on stdout
  BlackiceProbe --check URL1 URL2 [URL3]  Validate inputs only; no network or window
  BlackiceProbe --gui [SERVICE TELEMETRY] Open buttons; no request until clicked
  BlackiceProbe --help                   No network or window
With no arguments, show Service and Telemetry buttons for example.com/httpbingo.org.
HTTPS DNS names on port 443 only; no credentials, queries, fragments or redirects.
Exit 0 requires all CLI results to be 2xx over observed fresh TLS/TCP; else 1.
Failed requests are not proof of filter denial: correlate the filter's receipts.
"""

@MainActor final class ProbeWindow: NSObject, NSApplicationDelegate {
    private let targets: [ProbeTarget]
    private var window: NSWindow?
    private var results: [NSTextField] = []
    private var buttons: [NSButton] = []

    init(targets: [ProbeTarget]) { self.targets = targets }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 310),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Blackice Probe"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Two destinations. One test app.")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "Each button makes a real HTTPS request. Telemetry is a test role; no telemetry data is collected or sent.")
        description.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, description])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        for (index, target) in targets.enumerated() {
            let button = NSButton(title: target.label, target: self, action: #selector(fetch(_:)))
            button.tag = index
            button.font = .systemFont(ofSize: 16, weight: .medium)
            let host = NSTextField(labelWithString: target.url.host ?? "")
            host.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            let result = NSTextField(labelWithString: "Ready")
            result.textColor = .secondaryLabelColor
            let row = NSStackView(views: [button, host, result])
            row.orientation = .horizontal
            row.spacing = 12
            stack.addArrangedSubview(row)
            buttons.append(button); results.append(result)
        }
        let note = NSTextField(wrappingLabelWithString: "A failed request needs a matching filter receipt before it can be called blocked.")
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func fetch(_ button: NSButton) {
        let index = button.tag
        buttons.forEach { $0.isEnabled = false }
        results[index].stringValue = "Requesting…"
        let fetch = ProbeFetch(target: targets[index]) { [weak self] result in
            FileHandle.standardOutput.write(probeJSON(result))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.results[index].stringValue = result.outcome == "http_response" ?
                    "HTTP \(result.status ?? 0) · \(result.networkProtocol ?? "?")" :
                    "Failed: \(result.outcome)"
                self.buttons.forEach { $0.isEnabled = true }
            }
        }
        fetch.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// CLI results cross a delegate queue; keep the shared aggregate behind a lock.
final class ProbeCLIState: @unchecked Sendable {
    private let lock = NSLock()
    private var allPassed = true
    func record(_ result: ProbeResult) { lock.lock(); defer { lock.unlock() }; allPassed = allPassed && result.succeeded }
    var passed: Bool { lock.lock(); defer { lock.unlock() }; return allPassed }
}

do {
    switch try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(usage)
    case .check(let targets):
        // Only caller-supplied, validated public URLs are printed in this mode.
        FileHandle.standardOutput.write(probeJSON(targets))
    case .cli(let targets):
        let state = ProbeCLIState()
        for target in targets {
            let done = DispatchSemaphore(value: 0)
            let fetch = ProbeFetch(target: target) { result in
                FileHandle.standardOutput.write(probeJSON(result))
                state.record(result)
                done.signal()
            }
            fetch.start()
            guard done.wait(timeout: .now() + 25) == .success else {
                FileHandle.standardError.write(Data("probe_request_watchdog_timeout\n".utf8)); exit(1)
            }
        }
        exit(state.passed ? 0 : 1)
    case .gui(let targets):
        let app = NSApplication.shared
        let delegate = ProbeWindow(targets: targets)
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
} catch {
    FileHandle.standardError.write(Data("probe_invalid_arguments: use --help; HTTPS URLs must have no credentials, query or fragment\n".utf8))
    exit(2)
}
