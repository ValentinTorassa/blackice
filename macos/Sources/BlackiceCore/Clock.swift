import Darwin
import Foundation

/// Seconds since an arbitrary point, on a clock that keeps counting while the Mac sleeps:
/// CLOCK_MONOTONIC, which on macOS is mach_continuous_time. The filter times approvals, denials,
/// waiting connections and DNS answers with it. Until 1.0.2 it used the system uptime, which stops
/// during sleep, so an approval for 1 h was still valid after 2 h asleep.
public func continuousSeconds() -> TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
}
