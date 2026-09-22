import Foundation

let version = "macvault 0.1.0"

let helpText = """
macvault — local project materials utility

Usage:
  macvault init --vault <dir>
  macvault import --vault <dir> --source <dir> --json
  macvault list --vault <dir> --json [--name <substring>]
  macvault -h | --help
  macvault --version

Commands:
  init    Create <vault>/catalog.sqlite3 and <vault>/objects.
          Safe to re-run; existing vault data is never cleared.
  import  Recursively receive regular files from <source> into the vault,
          storing each distinct content once under objects/<sha256>.
          Prints a JSON object with imported, unchanged and reusedObjects.
  list    Print catalog entries as a JSON array sorted by relative path
          then id. --name filters file names by case-insensitive substring.

Options:
  --vault <dir>     Vault directory.
  --source <dir>    Source directory to import from.
  --json            Emit machine-readable JSON output.
  --name <substr>   Filter entries by file name substring.
  -h, --help        Show this help.
  --version         Show the program version.
"""

func writeError(_ message: String) {
    FileHandle.standardError.write(Data("macvault: error: \(message)\n".utf8))
}

func usageFailure(_ message: String) -> Never {
    writeError("\(message)\nRun 'macvault --help' for usage information.")
    exit(64)
}

func runtimeFailure(_ message: String) -> Never {
    writeError(message)
    exit(1)
}

struct ParsedArguments {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []
}

/// Parses `--option value`, `--option=value` and boolean flags. Duplicate
/// options, options missing a value, and unknown options are usage errors.
func parseCommandArguments(_ arguments: [String],
                           valueOptions: Set<String>,
                           flagOptions: Set<String>) -> ParsedArguments {
    var parsed = ParsedArguments()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        guard argument.hasPrefix("--") else {
            parsed.positionals.append(argument)
            index += 1
            continue
        }

        var key = argument
        var inlineValue: String?
        if let equals = argument.firstIndex(of: "=") {
            key = String(argument[..<equals])
            inlineValue = String(argument[argument.index(after: equals)...])
        }

        if valueOptions.contains(key) {
            let value: String
            if let inline = inlineValue {
                value = inline
            } else {
                let next = index + 1
                guard next < arguments.count, !arguments[next].hasPrefix("-") else {
                    usageFailure("option \(key) requires a value")
                }
                value = arguments[next]
                index = next
            }
            guard parsed.values[key] == nil else {
                usageFailure("option \(key) specified more than once")
            }
            parsed.values[key] = value
        } else if flagOptions.contains(key) {
            guard inlineValue == nil else {
                usageFailure("option \(key) does not take a value")
            }
            guard parsed.flags.insert(key).inserted else {
                usageFailure("option \(key) specified more than once")
            }
        } else {
            usageFailure("unknown option '\(key)'")
        }
        index += 1
    }
    return parsed
}

func requireNoPositionals(_ parsed: ParsedArguments) {
    guard parsed.positionals.isEmpty else {
        usageFailure("unexpected argument '\(parsed.positionals[0])'")
    }
}

func requireOptions(_ parsed: ParsedArguments, names: String...) -> [String: String] {
    for name in names where parsed.values[name] == nil {
        usageFailure("missing required option \(name)")
    }
    return parsed.values
}

func writeJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        runtimeFailure("cannot encode JSON output: \(error.localizedDescription)")
    }
}

// MARK: - Command dispatch

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "-h", "--help":
    guard arguments.allSatisfy({ $0 == "-h" || $0 == "--help" }) else {
        usageFailure("help takes no arguments")
    }
    print(helpText)
case "--version":
    guard arguments.count == 1 else {
        usageFailure("--version takes no arguments")
    }
    print(version)
case "init":
    let parsed = parseCommandArguments(Array(arguments.dropFirst()),
                                       valueOptions: ["--vault"],
                                       flagOptions: [])
    requireNoPositionals(parsed)
    let initOptions = requireOptions(parsed, names: "--vault")
    do {
        try Vault.initialize(vaultPath: initOptions["--vault"]!)
    } catch let error as VaultError {
        runtimeFailure(error.description)
    } catch {
        runtimeFailure(error.localizedDescription)
    }
case "import":
    let parsed = parseCommandArguments(Array(arguments.dropFirst()),
                                       valueOptions: ["--vault", "--source"],
                                       flagOptions: ["--json"])
    requireNoPositionals(parsed)
    let importOptions = requireOptions(parsed, names: "--vault", "--source")
    guard parsed.flags.contains("--json") else {
        usageFailure("missing required option --json")
    }
    do {
        let result = try Vault.import(vaultPath: importOptions["--vault"]!,
                                      sourcePath: importOptions["--source"]!)
        writeJSON(result)
    } catch let error as VaultError {
        runtimeFailure(error.description)
    } catch {
        runtimeFailure(error.localizedDescription)
    }
case "list":
    let parsed = parseCommandArguments(Array(arguments.dropFirst()),
                                       valueOptions: ["--vault", "--name"],
                                       flagOptions: ["--json"])
    requireNoPositionals(parsed)
    let listOptions = requireOptions(parsed, names: "--vault")
    guard parsed.flags.contains("--json") else {
        usageFailure("missing required option --json")
    }
    do {
        let entries = try Vault.list(vaultPath: listOptions["--vault"]!,
                                     nameSubstring: parsed.values["--name"])
        writeJSON(entries)
    } catch let error as VaultError {
        runtimeFailure(error.description)
    } catch {
        runtimeFailure(error.localizedDescription)
    }
case let command?:
    usageFailure("unknown command '\(command)'")
}
