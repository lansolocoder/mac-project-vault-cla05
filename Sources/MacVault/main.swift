import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments {
case [], ["--help"], ["-h"]:
    print("""
    macvault — local project materials utility

    Usage: macvault [--help | --version]

    Options:
      -h, --help   Show this help.
      --version    Show the program version.
    """)
case ["--version"]:
    print("macvault 0.1.0")
default:
    let message = "error: unsupported arguments; use macvault --help\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(64)
}
