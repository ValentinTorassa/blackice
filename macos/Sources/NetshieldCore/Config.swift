import Foundation

// netshield.toml: a strict reader for the small subset of TOML the file uses.
//
// Accepted: comments, bare keys, "basic" and 'literal' strings on one line, decimal
// integers, true/false, arrays of those (they may span lines), and the [[allow]] and
// [[hook]] tables. Everything else in TOML is refused with a line number instead of
// being guessed at: dotted or quoted keys, [tables], inline tables, multi-line
// strings, floats, dates, other number forms, unknown keys and duplicate keys.

public enum Mode: String, CaseIterable, Sendable {
    case acceptAll = "accept-all"
    case ask
    case blockAll = "block-all"
}

/// A permanent rule: this app may reach these hosts, in every mode.
public struct AllowRule: Equatable, Sendable {
    /// The signing identifier, checked against the running code.
    public let app: String
    /// The Team ID. nil means Apple platform code, which is signed without one.
    public let team: String?
    public let hosts: [DomainPattern]
    /// Line of the rule's [[allow]] header.
    public let line: Int

    /// `host` must already be normalized.
    public func matches(_ identity: SigningIdentity, host: String) -> Bool {
        identity.signingID == app && identity.teamID == team && hosts.contains { $0.matches(host) }
    }
}

public struct Hook: Equatable, Sendable {
    /// The only event so far is "connection".
    public let on: String
    /// The command line to run.
    public let run: String
    /// Line of the hook's [[hook]] header.
    public let line: Int
}

public struct ConfigError: Error, Equatable, CustomStringConvertible, Sendable {
    /// 1-based line, or nil for a problem with the whole file.
    public let line: Int?
    public let message: String

    public init(line: Int?, _ message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { line.map { "line \($0): \(message)" } ?? message }
}

public struct NetshieldConfig: Equatable, Sendable {
    public static let maximumBytes = 65_536
    public static let defaultTimeoutSeconds = 10
    /// Provisional. The upper bound comes down once the paused flow lifetime is measured.
    public static let timeoutRange = 1...120
    public static let maximumAllowRules = 256
    public static let maximumHostsPerRule = 256
    public static let maximumHooks = 8
    public static let maximumRunBytes = 4096

    public let mode: Mode
    public let timeoutSeconds: Int
    public let allow: [AllowRule]
    public let hooks: [Hook]

    public init(data: Data) throws {
        guard !data.isEmpty else { throw ConfigError(line: nil, "the file is empty") }
        guard data.count <= Self.maximumBytes else {
            throw ConfigError(line: nil, "the file is larger than \(Self.maximumBytes / 1024) KiB")
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { throw ConfigError(line: 1, "byte order marks are not supported") }
        guard String(data: data, encoding: .utf8) != nil else { throw ConfigError(line: nil, "the file is not valid UTF-8") }
        var parser = Parser(bytes: Array(data))
        let document = try parser.parse()
        self = try Self.build(document)
    }

    public init(text: String) throws { try self.init(data: Data(text.utf8)) }

    private init(mode: Mode, timeoutSeconds: Int, allow: [AllowRule], hooks: [Hook]) {
        self.mode = mode
        self.timeoutSeconds = timeoutSeconds
        self.allow = allow
        self.hooks = hooks
    }

    /// The first rule that lets this app reach this host, if any. Rules say nothing about ports.
    public func allowRule(for identity: SigningIdentity, host: String) -> AllowRule? {
        guard let host = normalizeHost(host) else { return nil }
        return allow.first { $0.matches(identity, host: host) }
    }

    public var summary: String {
        let rules = allow.count == 1 ? "1 allow rule" : "\(allow.count) allow rules"
        let hookCount = hooks.count == 1 ? "1 hook" : "\(hooks.count) hooks"
        return "mode \(mode.rawValue), timeout \(timeoutSeconds) s, \(rules), \(hookCount)"
    }
}

// MARK: - Building the configuration from the parsed tables

extension NetshieldConfig {
    private static func build(_ document: Document) throws -> NetshieldConfig {
        let root = document.root
        guard let modeEntry = root.entries["mode"] else { throw ConfigError(line: nil, "missing required key 'mode'") }
        let modeText = try modeEntry.string("mode")
        guard let mode = Mode(rawValue: modeText) else {
            throw ConfigError(line: modeEntry.line, "mode must be \"accept-all\", \"ask\" or \"block-all\", not \(quoted(modeText))")
        }
        var timeout = defaultTimeoutSeconds
        if let entry = root.entries["timeout_seconds"] {
            timeout = try entry.integer("timeout_seconds")
            guard timeoutRange.contains(timeout) else {
                throw ConfigError(line: entry.line, "timeout_seconds must be between \(timeoutRange.lowerBound) and \(timeoutRange.upperBound)")
            }
        }
        let allowTables = document.tables.filter { $0.kind == .allow }
        let hookTables = document.tables.filter { $0.kind == .hook }
        if allowTables.count > maximumAllowRules {
            throw ConfigError(line: allowTables[maximumAllowRules].line, "more than \(maximumAllowRules) [[allow]] rules")
        }
        if hookTables.count > maximumHooks {
            throw ConfigError(line: hookTables[maximumHooks].line, "more than \(maximumHooks) [[hook]] tables")
        }
        return NetshieldConfig(mode: mode, timeoutSeconds: timeout,
                               allow: try allowTables.map(allowRule), hooks: try hookTables.map(hook))
    }

    private static func allowRule(_ table: Table) throws -> AllowRule {
        guard let appEntry = table.entries["app"] else { throw ConfigError(line: table.line, "[[allow]] needs an 'app' key") }
        let app = try appEntry.string("app")
        guard validSigningID(app) else {
            throw ConfigError(line: appEntry.line, "app must be a signing identifier (letters, digits, '-', '.', '_'), not \(quoted(app))")
        }
        var team: String?
        if let entry = table.entries["team"] {
            let text = try entry.string("team")
            guard validTeamID(text) else {
                throw ConfigError(line: entry.line, "team must be a Team ID of 10 upper-case letters or digits, not \(quoted(text))")
            }
            team = text
        }
        guard let hostsEntry = table.entries["hosts"] else { throw ConfigError(line: table.line, "[[allow]] needs a 'hosts' key") }
        guard case .array(let items) = hostsEntry.value else {
            throw ConfigError(line: hostsEntry.line, "hosts must be an array of strings, not \(hostsEntry.value.typeName)")
        }
        guard !items.isEmpty else { throw ConfigError(line: hostsEntry.line, "hosts must not be empty") }
        guard items.count <= maximumHostsPerRule else {
            throw ConfigError(line: hostsEntry.line, "hosts has more than \(maximumHostsPerRule) entries")
        }
        var patterns: [DomainPattern] = []
        var seen = Set<String>()
        for item in items {
            guard case .string(let text) = item else {
                throw ConfigError(line: hostsEntry.line, "hosts must be an array of strings, but it holds \(item.typeName)")
            }
            guard let pattern = DomainPattern(text) else {
                throw ConfigError(line: hostsEntry.line, "\(quoted(text)) is not a host name or a *.domain pattern")
            }
            guard seen.insert((pattern.wildcard ? "*" : "") + pattern.suffix).inserted else {
                throw ConfigError(line: hostsEntry.line, "\(quoted(text)) appears twice in hosts")
            }
            patterns.append(pattern)
        }
        return AllowRule(app: app, team: team, hosts: patterns, line: table.line)
    }

    private static func hook(_ table: Table) throws -> Hook {
        guard let onEntry = table.entries["on"] else { throw ConfigError(line: table.line, "[[hook]] needs an 'on' key") }
        let on = try onEntry.string("on")
        guard on == "connection" else {
            throw ConfigError(line: onEntry.line, "on must be \"connection\", not \(quoted(on))")
        }
        guard let runEntry = table.entries["run"] else { throw ConfigError(line: table.line, "[[hook]] needs a 'run' key") }
        let run = try runEntry.string("run")
        guard !run.allSatisfy({ $0 == " " || $0 == "\t" }) else { throw ConfigError(line: runEntry.line, "run must not be empty") }
        guard run.utf8.count <= maximumRunBytes else {
            throw ConfigError(line: runEntry.line, "run is longer than \(maximumRunBytes) bytes")
        }
        guard !run.unicodeScalars.contains(where: isControl) else {
            throw ConfigError(line: runEntry.line, "run must be one line with no control characters")
        }
        return Hook(on: on, run: run, line: table.line)
    }
}

/// C0 controls other than tab, DEL and C1 controls.
private func isControl(_ scalar: Unicode.Scalar) -> Bool {
    (scalar.value < 0x20 && scalar.value != 0x09) || (0x7F...0x9F).contains(scalar.value)
}

/// A value from the file, safe to print: printable ASCII is kept, the rest is escaped, and long values are cut.
func quoted(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars.prefix(64) {
        if (0x20...0x7E).contains(scalar.value), scalar != "\"", scalar != "\\" {
            out.unicodeScalars.append(scalar)
        } else {
            out += "\\u{" + String(scalar.value, radix: 16) + "}"
        }
    }
    return "\"" + out + (text.unicodeScalars.count > 64 ? "…" : "") + "\""
}

// MARK: - Parsed document

private enum Value: Equatable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case array([Value])

    var typeName: String {
        switch self {
        case .string: return "a string"
        case .integer: return "an integer"
        case .bool: return "a boolean"
        case .array: return "an array"
        }
    }
}

private struct Entry {
    let value: Value
    let line: Int

    func string(_ key: String) throws -> String {
        guard case .string(let text) = value else { throw ConfigError(line: line, "\(key) must be a string, not \(value.typeName)") }
        return text
    }

    func integer(_ key: String) throws -> Int {
        guard case .integer(let number) = value else { throw ConfigError(line: line, "\(key) must be an integer, not \(value.typeName)") }
        return number
    }
}

private enum TableKind: String {
    case root, allow, hook

    var keys: Set<String> {
        switch self {
        case .root: return ["mode", "timeout_seconds"]
        case .allow: return ["app", "team", "hosts"]
        case .hook: return ["on", "run"]
        }
    }

    var label: String { self == .root ? "at the top level" : "in [[\(rawValue)]]" }
}

private struct Table {
    let kind: TableKind
    let line: Int
    var entries: [String: Entry] = [:]
}

private struct Document {
    var root = Table(kind: .root, line: 1)
    var tables: [Table] = []
}

// MARK: - Parser

private struct Parser {
    static let maximumArrayItems = 1024

    let bytes: [UInt8]
    var index = 0
    var line = 1

    init(bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { index >= bytes.count }
    var current: UInt8? { atEnd ? nil : bytes[index] }

    func peek(_ offset: Int) -> UInt8? {
        index + offset < bytes.count ? bytes[index + offset] : nil
    }

    func fail(_ message: String) -> ConfigError { ConfigError(line: line, message) }

    mutating func parse() throws -> Document {
        var document = Document()
        while !atEnd {
            skipSpaces()
            guard let byte = current else { break }
            if try consumeNewline() { continue }
            if byte == UInt8(ascii: "#") { try skipComment(); continue }
            if byte == UInt8(ascii: "[") {
                document.tables.append(try parseHeader())
                continue
            }
            let keyLine = line
            let key = try parseKey()
            skipSpaces()
            guard current == UInt8(ascii: "=") else {
                if current == UInt8(ascii: ".") { throw fail("dotted keys are not supported") }
                throw fail("expected '=' after the key '\(key)'")
            }
            index += 1
            skipSpaces()
            let value = try parseValue(inArray: false)
            try expectEndOfLine()
            if document.tables.isEmpty {
                try add(key, value, line: keyLine, to: &document.root)
            } else {
                try add(key, value, line: keyLine, to: &document.tables[document.tables.count - 1])
            }
        }
        return document
    }

    func add(_ key: String, _ value: Value, line keyLine: Int, to table: inout Table) throws {
        guard table.kind.keys.contains(key) else {
            var message = "unknown key '\(key)' \(table.kind.label)"
            if table.kind != .root, TableKind.root.keys.contains(key) {
                message += "; top-level keys go before the first table"
            }
            throw ConfigError(line: keyLine, message)
        }
        if let first = table.entries[key] {
            throw ConfigError(line: keyLine, "duplicate key '\(key)' \(table.kind.label) (first set on line \(first.line))")
        }
        table.entries[key] = Entry(value: value, line: keyLine)
    }

    mutating func parseHeader() throws -> Table {
        let headerLine = line
        guard peek(1) == UInt8(ascii: "[") else {
            throw fail("only [[allow]] and [[hook]] tables are supported")
        }
        index += 2
        skipSpaces()
        let name = try parseKey()
        skipSpaces()
        if current == UInt8(ascii: ".") { throw fail("dotted table names are not supported") }
        guard current == UInt8(ascii: "]"), peek(1) == UInt8(ascii: "]") else { throw fail("expected ']]' after the table name") }
        index += 2
        try expectEndOfLine()
        switch name {
        case "allow": return Table(kind: .allow, line: headerLine)
        case "hook": return Table(kind: .hook, line: headerLine)
        default: throw ConfigError(line: headerLine, "unknown table [[\(name)]]; only [[allow]] and [[hook]] are supported")
        }
    }

    mutating func parseKey() throws -> String {
        if current == UInt8(ascii: "\"") || current == UInt8(ascii: "'") { throw fail("quoted keys are not supported") }
        let start = index
        while let byte = current, isBareKeyByte(byte) { index += 1 }
        guard index > start else {
            if let byte = current, isControlByte(byte) { throw fail("control character outside a string") }
            throw fail("expected a key")
        }
        guard index - start <= 64 else { throw fail("key longer than 64 characters") }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func parseValue(inArray: Bool) throws -> Value {
        guard let byte = current else { throw fail("expected a value") }
        switch byte {
        case UInt8(ascii: "\""):
            if peek(1) == UInt8(ascii: "\""), peek(2) == UInt8(ascii: "\"") { throw fail("multi-line strings are not supported") }
            return .string(try parseBasicString())
        case UInt8(ascii: "'"):
            if peek(1) == UInt8(ascii: "'"), peek(2) == UInt8(ascii: "'") { throw fail("multi-line strings are not supported") }
            return .string(try parseLiteralString())
        case UInt8(ascii: "["):
            if inArray { throw fail("nested arrays are not supported") }
            return .array(try parseArray())
        case UInt8(ascii: "{"):
            throw fail("inline tables are not supported")
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "-"):
            return .integer(try parseInteger())
        default:
            let start = index
            while let next = current, isBareKeyByte(next) { index += 1 }
            let word = String(decoding: bytes[start..<index], as: UTF8.self)
            if word == "true" { return .bool(true) }
            if word == "false" { return .bool(false) }
            if word.isEmpty { throw fail("expected a value") }
            throw fail("unsupported value '\(word.prefix(32))'; strings need quotes")
        }
    }

    mutating func parseInteger() throws -> Int {
        let start = index
        while let byte = current, isBareKeyByte(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: ":") {
            index += 1
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        let digitsOnly = !token.isEmpty && token.utf8.allSatisfy { (48...57).contains($0) }
        guard digitsOnly, token == "0" || !token.hasPrefix("0"), token.count <= 9, let value = Int(token) else {
            throw fail("unsupported number '\(token.prefix(32))'; write a plain decimal integer such as 10")
        }
        return value
    }

    mutating func parseBasicString() throws -> String {
        index += 1
        var out: [UInt8] = []
        while true {
            guard let byte = current, byte != 0x0A, byte != 0x0D else { throw fail("unterminated string") }
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let escape = current else { throw fail("unterminated string") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "u"): out += try parseUnicodeEscape(digits: 4)
                case UInt8(ascii: "U"): out += try parseUnicodeEscape(digits: 8)
                default: throw fail("invalid escape in string")
                }
            default:
                if isControlByte(byte) && byte != 0x09 { throw fail("control character in string") }
                out.append(byte)
            }
        }
    }

    mutating func parseUnicodeEscape(digits: Int) throws -> [UInt8] {
        guard index + digits <= bytes.count else { throw fail("invalid escape in string") }
        let hex = String(decoding: bytes[index..<(index + digits)], as: UTF8.self)
        guard hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw fail("invalid escape in string")
        }
        index += digits
        return Array(String(Character(scalar)).utf8)
    }

    mutating func parseLiteralString() throws -> String {
        index += 1
        let start = index
        while true {
            guard let byte = current, byte != 0x0A, byte != 0x0D else { throw fail("unterminated string") }
            if byte == UInt8(ascii: "'") {
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return text
            }
            if isControlByte(byte) && byte != 0x09 { throw fail("control character in string") }
            index += 1
        }
    }

    mutating func parseArray() throws -> [Value] {
        index += 1
        var items: [Value] = []
        while true {
            try skipSpacesNewlinesAndComments()
            guard let byte = current else { throw fail("unterminated array") }
            if byte == UInt8(ascii: "]") { index += 1; return items }
            items.append(try parseValue(inArray: true))
            guard items.count <= Self.maximumArrayItems else { throw fail("array with more than \(Self.maximumArrayItems) items") }
            try skipSpacesNewlinesAndComments()
            guard let separator = current else { throw fail("unterminated array") }
            if separator == UInt8(ascii: ",") { index += 1; continue }
            if separator == UInt8(ascii: "]") { index += 1; return items }
            throw fail("expected ',' or ']' in array")
        }
    }

    mutating func skipSpaces() {
        while let byte = current, byte == 0x20 || byte == 0x09 { index += 1 }
    }

    /// Consumes LF or CRLF. A lone CR is an error.
    mutating func consumeNewline() throws -> Bool {
        if current == 0x0A { index += 1; line += 1; return true }
        if current == 0x0D {
            guard peek(1) == 0x0A else { throw fail("carriage return without a line feed") }
            index += 2; line += 1; return true
        }
        return false
    }

    mutating func skipComment() throws {
        index += 1
        while let byte = current, byte != 0x0A, byte != 0x0D {
            if isControlByte(byte) && byte != 0x09 { throw fail("control character in comment") }
            index += 1
        }
    }

    mutating func skipSpacesNewlinesAndComments() throws {
        while true {
            skipSpaces()
            if try consumeNewline() { continue }
            if current == UInt8(ascii: "#") { try skipComment(); continue }
            return
        }
    }

    /// After a value or a header: spaces, an optional comment, then a newline or the end of the file.
    mutating func expectEndOfLine() throws {
        skipSpaces()
        if current == UInt8(ascii: "#") { try skipComment() }
        if atEnd { return }
        guard try consumeNewline() else { throw fail("unexpected text after the value") }
    }
}

private func isBareKeyByte(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
}

private func isControlByte(_ byte: UInt8) -> Bool { byte < 0x20 || byte == 0x7F }
