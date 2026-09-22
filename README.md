# Mac Project Vault

A command-line entry point for working with local project materials on macOS.

Requires macOS 13 or newer and Swift 6. No external dependencies.

```sh
swift build
.build/debug/macvault --help
.build/debug/macvault --version
.build/debug/macvault compare OLD NEW
```

No arguments or `-h`/`--help` display help; `--version` prints the version.
Unsupported arguments write an error to stderr and exit with status 64.

## `macvault compare OLD NEW`

Recursively compares two directories read-only (neither directory is modified)
and prints the differences as a single JSON array on stdout. Both arguments
must be different existing directories, otherwise an error is written to
stderr and the program exits with status 64.

Only regular files are considered; symbolic links are never followed. Relative
paths use `/` separators and are ordered by their UTF-8 bytes. File contents
are compared by lowercase SHA-256 and byte size:

- same path, same hash: not reported
- same path, different hash: `modified`
- a hash present on exactly one path of each unmatched side: `moved`
- otherwise: `removed` (old only) or `added` (new only)

Each entry has the fixed keys `kind`, `oldPath`, `newPath`, `oldSha256`,
`newSha256`, `oldSize`, `newSize`, with `null` for the missing side. Entries
are stably sorted by `oldPath` (nulls last), `newPath`, then `kind`, in UTF-8
byte order. An empty difference prints `[]`.

If any file is unreadable, disappears, or changes size or modification time
while being read, stdout stays empty, the affected paths are written to
stderr in stable path order, and the program exits with status 74.
