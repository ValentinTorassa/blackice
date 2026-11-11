// Reads the kernel's lists of content filters and of the sockets attached to them, to tell when
// macOS has not finished disconnecting a filter that stopped (FilterDisconnect). Any process may
// read them; nothing here changes anything.
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

    /// How many content filters the kernel has; nil when their list cannot be read.
    static func count() -> Int? {
        read("net.cfil.filter_list").flatMap(FilterDisconnect.count(filters:))
    }

    /// The filter the kernel is disconnecting now, if any. The sockets are read only then.
    static func disconnect() -> FilterDisconnect? {
        guard let filters = read("net.cfil.filter_list"),
              FilterDisconnect(filters: filters, sockets: Data()) != nil else { return nil }
        return FilterDisconnect(filters: filters, sockets: read("net.cfil.sock_list") ?? Data())
    }

    /// A disconnect that lasts: nil unless the kernel is disconnecting a filter and still is
    /// `lasting` seconds later. One that goes well takes milliseconds.
    ///
    /// `before` is how many filters the kernel had before one was told to stop. With it this
    /// first waits, for at most `appear` seconds, until the kernel has fewer filters or is
    /// disconnecting one: the stop reaches the kernel some time after the preferences are saved.
    static func held(after before: Int? = nil, appear: TimeInterval = 2, lasting: TimeInterval = 1,
                     interval: TimeInterval = 0.05) -> HeldDisconnect? {
        if let before {
            let limit = Date().addingTimeInterval(appear)
            while disconnect() == nil {
                guard let now = count(), now >= before, Date() < limit else { return nil }
                Thread.sleep(forTimeInterval: interval)
            }
        }
        guard disconnect() != nil else { return nil }
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
