// Reads the kernel's lists of content filters and of the sockets attached to them, to tell when
// macOS has not finished disconnecting a filter that another replaced (FilterDisconnect). Any
// process may read them; nothing here changes anything.
import Foundation
import BlackiceCLI
import BlackiceCore

enum KernelFilters {
    /// A sysctl's bytes; nil when the kernel has no such name or the read fails.
    static func read(_ name: String) -> Data? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        // The list can grow between the two calls.
        size += 16_384
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0, size <= bytes.count else { return nil }
        return Data(bytes[0..<size])
    }

    /// How many content filters the kernel lists; nil when the list cannot be read or is laid out
    /// another way than FilterDisconnect knows.
    static func count() -> Int? {
        read("net.cfil.filter_list").flatMap(FilterDisconnect.count(filters:))
    }

    /// After a filter was turned off, the kernel's list having had `before` filters until then:
    /// waits until the kernel has finished disconnecting it, so that the filter started next is
    /// not held with it (FilterDisconnect). false when the kernel is still at it after `limit`
    /// seconds. `held` is told once, with the socket the kernel is at, when it has lasted
    /// `lasting` seconds.
    ///
    /// The stop reaches the kernel a moment after the settings are saved: a list that still has
    /// `before` filters and none going is waited on for `appear` seconds (FilterDisconnect.wait).
    /// Nothing is waited for when the list cannot be read.
    static func gone(after before: Int, appear: TimeInterval = 2, lasting: TimeInterval = 1, limit: TimeInterval = 30,
                     interval: TimeInterval = 0.05, held: (HeldDisconnect) -> Void) -> Bool {
        let start = Date()
        var told = false
        while true {
            let waited = Date().timeIntervalSince(start)
            guard let filters = read("net.cfil.filter_list"),
                  let progress = FilterDisconnect.progress(filters: filters, before: before) else { return true }
            switch FilterDisconnect.wait(progress, waited: waited, appear: appear, limit: limit) {
            case .done: return true
            case .tooLong: return false
            case .again: break
            }
            if progress == .going, !told, waited >= lasting {
                told = true
                if let disconnect = FilterDisconnect(filters: filters, sockets: read("net.cfil.sock_list") ?? Data(),
                                                     replacedOnly: false) {
                    held(HeldDisconnect(disconnect, process: disconnect.pid.flatMap(name)))
                }
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// The filter the kernel is disconnecting now while another runs in its place, if any. The
    /// sockets are read only then.
    static func disconnect() -> FilterDisconnect? {
        guard let filters = read("net.cfil.filter_list"),
              FilterDisconnect(filters: filters, sockets: Data()) != nil else { return nil }
        return FilterDisconnect(filters: filters, sockets: read("net.cfil.sock_list") ?? Data())
    }

    /// A disconnect that lasts: nil unless the kernel is at one and still is `lasting` seconds
    /// later. One that goes well takes milliseconds.
    ///
    /// `appear` is how long to wait for the filter that takes the place of one that is going: the
    /// kernel lists a filter a moment after the filter has started (within 0.11 s in the two
    /// replacements recorded on 11 November 2026). Nothing is waited for when no filter is going.
    static func held(appear: TimeInterval = 0, lasting: TimeInterval = 1, interval: TimeInterval = 0.05) -> HeldDisconnect? {
        let registered = Date().addingTimeInterval(appear)
        while disconnect() == nil {
            guard Date() < registered, read("net.cfil.filter_list").map(FilterDisconnect.going(filters:)) == true else { return nil }
            Thread.sleep(forTimeInterval: interval)
        }
        let limit = Date().addingTimeInterval(lasting)
        while Date() < limit {
            Thread.sleep(forTimeInterval: interval)
            if disconnect() == nil { return nil }
        }
        guard let disconnect = disconnect() else { return nil }
        return HeldDisconnect(disconnect, process: disconnect.pid.flatMap(name))
    }

    /// A process's name: the last part of its executable's path.
    static func name(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
