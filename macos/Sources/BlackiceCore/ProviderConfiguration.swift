import CryptoKit
import Foundation

// What the CLI saves in the filter's provider configuration and the extension reads back:
// the blackice.toml text, the current mode (blackice mode changes it without editing the
// file) and a generation that only goes up. Stored as one JSON value under one key of
// NEFilterProviderConfiguration.vendorConfiguration. The extension never reads user files.

public struct ProviderConfigurationError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct ProviderConfiguration: Equatable, Sendable {
    public static let vendorKey = "blackice.configuration"
    public static let format = "blackice.provider/v1"
    /// The largest TOML text once escaped as JSON, which can double it, plus a little JSON around
    /// it. `encoded` and `init(data:)` both hold to it.
    public static let maximumBytes = Messages.jsonStringBytes(BlackiceConfig.maximumBytes) + 4096

    public let generation: UInt64
    public let mode: Mode
    public let configText: String
    public let config: BlackiceConfig

    public init(generation: UInt64, mode: Mode, configText: String) throws {
        guard generation > 0 else { throw ProviderConfigurationError("generation must be at least 1") }
        self.generation = generation
        self.mode = mode
        self.configText = configText
        self.config = try BlackiceConfig(text: configText)
    }

    /// A first configuration, or the next one after `previous`, in the file's own mode.
    public static func starting(configText: String, after previous: ProviderConfiguration?) throws -> ProviderConfiguration {
        let config = try BlackiceConfig(text: configText)
        return try ProviderConfiguration(generation: try nextGeneration(after: previous), mode: config.mode,
                                         configText: configText)
    }

    /// The same rules in another mode, one generation later.
    public func with(mode: Mode) throws -> ProviderConfiguration {
        try ProviderConfiguration(generation: try Self.nextGeneration(after: self), mode: mode, configText: configText)
    }

    /// In `mode`, with `answerer` answering, one generation later. When someone else answers now,
    /// the text gets `answers` in [agent] (`BlackiceConfig.settingAnswers`): the file on disk is not
    /// edited, as `blackice mode` leaves it, and `blackice start` loads its own `answers` again.
    public func with(mode: Mode, answerer: Answerer?) throws -> ProviderConfiguration {
        guard let answerer, answerer != config.answering.answerer else { return try with(mode: mode) }
        return try ProviderConfiguration(generation: try Self.nextGeneration(after: self), mode: mode,
                                         configText: try BlackiceConfig.settingAnswers(answerer, in: configText))
    }

    /// The same configuration, generation included, as if it were in `mode`, without parsing the
    /// text again. Never installed: accept-all's dry run of ask mode decides with it.
    func viewed(in mode: Mode) -> ProviderConfiguration {
        ProviderConfiguration(generation: generation, mode: mode, configText: configText, config: config)
    }

    private init(generation: UInt64, mode: Mode, configText: String, config: BlackiceConfig) {
        self.generation = generation
        self.mode = mode
        self.configText = configText
        self.config = config
    }

    private static func nextGeneration(after previous: ProviderConfiguration?) throws -> UInt64 {
        guard let previous else { return 1 }
        guard previous.generation < UInt64.max else { throw ProviderConfigurationError("generation overflow") }
        return previous.generation + 1
    }

    private struct Document: Codable {
        let format: String
        let generation: UInt64
        let mode: String
        let config: String
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Lists the keys of the top-level object so unknown ones can be refused.
    private struct KeyList: Decodable {
        let keys: Set<String>
        init(from decoder: Decoder) throws {
            keys = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
        }
    }

    /// Never more than the extension reads back.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(format: Self.format, generation: generation, mode: mode.rawValue,
                                               config: configText))
        guard data.count <= Self.maximumBytes else { throw ProviderConfigurationError("provider configuration too large") }
        return data
    }

    /// Strict: exactly the four keys, the known format, a valid mode and a blackice.toml that parses.
    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw ProviderConfigurationError("provider configuration too large") }
        let decoder = JSONDecoder()
        let keys: Set<String>
        let document: Document
        do {
            keys = try decoder.decode(KeyList.self, from: data).keys
            document = try decoder.decode(Document.self, from: data)
        } catch {
            throw ProviderConfigurationError("provider configuration is not valid JSON of the expected shape")
        }
        guard keys == ["format", "generation", "mode", "config"] else {
            throw ProviderConfigurationError("provider configuration has unexpected keys")
        }
        guard document.format == Self.format else { throw ProviderConfigurationError("unknown provider configuration format") }
        guard let mode = Mode(rawValue: document.mode) else { throw ProviderConfigurationError("unknown mode") }
        try self.init(generation: document.generation, mode: mode, configText: document.config)
    }

    public func vendorConfiguration() throws -> [String: Any] {
        [Self.vendorKey: try encoded()]
    }

    /// The saved vendor configuration must hold this key and nothing else.
    public init(vendorConfiguration: [String: Any]?) throws {
        guard let values = vendorConfiguration, Set(values.keys) == [Self.vendorKey],
              let data = values[Self.vendorKey] as? Data else {
            throw ProviderConfigurationError("missing provider configuration")
        }
        try self.init(data: data)
    }

    /// The SHA-256 of the blackice.toml text, in lower-case hex, so the extension can say which
    /// text it holds without sending it.
    public var configSHA256: String {
        SHA256.hash(data: Data(configText.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var summary: String {
        let rules = config.allow.count == 1 ? "1 allow rule" : "\(config.allow.count) allow rules"
        let hooks = config.activeHooks.count == 1 ? "1 hook" : "\(config.activeHooks.count) hooks"
        return "mode \(mode.rawValue), \(rules), \(hooks), generation \(generation)"
    }
}

/// The configuration the extension decides with. A notification that carries the same
/// configuration again changes nothing; an older generation never replaces a newer one.
public final class ProviderSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ProviderConfiguration?

    public init() {}

    public func read() -> ProviderConfiguration? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// True when the candidate replaced the snapshot.
    @discardableResult
    public func install(_ candidate: ProviderConfiguration) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let current {
            if candidate == current { return false }
            guard candidate.generation > current.generation else {
                throw ProviderConfigurationError("stale generation \(candidate.generation), current \(current.generation)")
            }
        }
        current = candidate
        return true
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        current = nil
    }
}
