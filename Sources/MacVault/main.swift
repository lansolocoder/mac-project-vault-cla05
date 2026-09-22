import Foundation

let helpText = """
macvault — local project materials utility

Usage: macvault [--help | --version]
       macvault compare OLD NEW
       macvault snapshot SOURCE SNAPSHOT
       macvault snapshot-diff SNAPSHOT CURRENT

Commands:
  compare OLD NEW              Recursively compare two directories read-only
                               and print the differences as a JSON array.
  snapshot SOURCE SNAPSHOT     Recursively capture regular files in SOURCE
                               into a new JSON snapshot file. SNAPSHOT must
                               not exist and must not be inside SOURCE.
  snapshot-diff SNAPSHOT CURRENT
                               Compare a snapshot (old side) with the CURRENT
                               directory (new side), same JSON output as
                               compare.

Options:
  -h, --help   Show this help.
  --version    Show the program version.
"""

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.count == 3, arguments[0] == "compare" {
    exit(runCompare(oldPath: arguments[1], newPath: arguments[2]))
}

if arguments.count == 3, arguments[0] == "snapshot" {
    exit(runSnapshot(sourcePath: arguments[1], snapshotPath: arguments[2]))
}

if arguments.count == 3, arguments[0] == "snapshot-diff" {
    exit(runSnapshotDiff(snapshotPath: arguments[1], currentPath: arguments[2]))
}

switch arguments {
case [], ["--help"], ["-h"]:
    print(helpText)
case ["--version"]:
    print("macvault 0.1.0")
default:
    let message = "error: unsupported arguments; use macvault --help\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(64)
}
