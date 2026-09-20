# Mac Project Vault

A command-line entry point for working with local project materials on macOS.

Requires macOS 13 or newer and Swift 6. No external dependencies.

```sh
swift build
.build/debug/macvault --help
.build/debug/macvault --version
```

The current version only displays help and version information. No arguments or
`-h` also display help. Unsupported arguments write an error to stderr and exit
with status 64. The program does not read, modify, or organize project files yet.
