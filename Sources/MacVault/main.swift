import Foundation

let helpText = """
macvault — local project materials utility

Usage: macvault [--help | --version]
       macvault compare OLD NEW
       macvault history-add ROOT P V SNAPSHOT
       macvault history-query ROOT [P [V [PATH]]]
       macvault snapshot SOURCE SNAPSHOT
       macvault snapshot-diff SNAPSHOT CURRENT

Commands:
  compare OLD NEW              Recursively compare two directories read-only
                               and print the differences as a JSON array.
  history-add ROOT P V SNAPSHOT
                               Strictly decode SNAPSHOT and register it under
                               project P and version V in the history store
                               ROOT, initializing ROOT if needed.
  history-query ROOT [P [V [PATH]]]
                               Print the history records under ROOT matching
                               the optional project, version, and file-path
                               filters as a JSON array.
  snapshot SOURCE SNAPSHOT     Recursively collect regular files below SOURCE
                               and atomically write a JSON snapshot.
  snapshot-diff SNAPSHOT CURRENT
                               Compare a snapshot against the CURRENT
                               directory read-only and print differences as a
                               JSON array, using the same semantics as
                               compare.

Options:
  -h, --help   Show this help.
  --version    Show the program version.
"""

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.count == 3, arguments[0] == "compare" {
    exit(runCompare(oldPath: arguments[1], newPath: arguments[2]))
}

if arguments.count == 5, arguments[0] == "history-add" {
    exit(runHistoryAdd(
        rootPath: arguments[1],
        project: arguments[2],
        version: arguments[3],
        snapshotPath: arguments[4]))
}

if arguments.count >= 2, arguments.count <= 5, arguments[0] == "history-query" {
    exit(runHistoryQuery(
        rootPath: arguments[1],
        project: arguments.count > 2 ? arguments[2] : nil,
        version: arguments.count > 3 ? arguments[3] : nil,
        path: arguments.count > 4 ? arguments[4] : nil))
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
