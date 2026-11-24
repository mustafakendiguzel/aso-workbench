import Foundation

/// A mistake in how the command was called. Reported with the command's usage and exit code 64 (EX_USAGE).
public struct UsageError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Command-line arguments split into positionals, `--name value` / `--name=value` options and boolean flags.
/// Everything after `--` is positional, so keywords that start with a dash can still be passed.
struct Arguments: Equatable {
    /// Options that take no value.
    static let flagNames: Set<String> = ["json", "help", "version", "stale", "key-stdin", "keys-stdin", "csv", "all", "new", "stdin", "on", "off", "yes", "create-missing"]

    private(set) var positionals: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String]) throws {
        var index = arguments.startIndex
        var onlyPositionals = false
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            if onlyPositionals || !argument.hasPrefix("-") || argument == "-" {
                positionals.append(argument)
            } else if argument == "--" {
                onlyPositionals = true
            } else if argument == "-h" {
                flags.insert("help")
            } else if argument.hasPrefix("--") {
                let body = argument.dropFirst(2)
                if let equals = body.firstIndex(of: "=") {
                    let name = String(body[..<equals])
                    guard !Self.flagNames.contains(name) else { throw UsageError("--\(name) does not take a value.") }
                    options[name] = String(body[body.index(after: equals)...])
                } else if Self.flagNames.contains(String(body)) {
                    flags.insert(String(body))
                } else {
                    guard index < arguments.endIndex else { throw UsageError("--\(body) needs a value.") }
                    options[String(body)] = arguments[index]
                    index += 1
                }
            } else {
                throw UsageError("Unknown option \(argument). Options are written --name value.")
            }
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func option(_ name: String) -> String? { options[name] }

    /// Every option and flag used, for rejecting ones a command does not know.
    var names: Set<String> { Set(options.keys).union(flags) }

    /// Fails on options the command does not accept (global options are always allowed).
    func allow(_ accepted: Set<String>) throws {
        let unknown = names.subtracting(accepted).subtracting(["json", "help", "data-dir"]).sorted()
        if let first = unknown.first { throw UsageError("Unknown option --\(first) for this command.") }
    }

    /// The positional at `index` (after the command words), or a usage error naming what is missing.
    func positional(_ index: Int, _ name: String) throws -> String {
        guard index < positionals.count else { throw UsageError("Missing \(name).") }
        return positionals[index]
    }

    func integer(_ index: Int, _ name: String) throws -> Int {
        let raw = try positional(index, name)
        guard let value = Int(raw) else { throw UsageError("\(name.capitalized) must be a number, got \"\(raw)\".") }
        return value
    }

    func integerOption(_ name: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = option(name) else { return value }
        guard let parsed = Int(raw), range.contains(parsed) else {
            throw UsageError("--\(name) must be a number from \(range.lowerBound) to \(range.upperBound).")
        }
        return parsed
    }
}
