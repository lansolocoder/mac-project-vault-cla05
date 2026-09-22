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

Recursively compares two directories read-only and prints the differences as a
single JSON array on stdout. Both arguments must be existing, distinct
directories; otherwise an error is written to stderr and the exit status is 64.
Neither directory is modified.

Only regular files are considered; symbolic links are not followed. Relative
paths use `/` separators and are ordered by their UTF-8 bytes. File contents
are compared by lowercase SHA-256 and byte count:

- `modified` — same relative path on both sides, different content.
- `moved` — a hash that appears exactly once among the unmatched files on each
  side (no many-to-many rename guessing).
- `removed` / `added` — everything else present on only one side.

Each entry has the fixed keys `kind`, `oldPath`, `newPath`, `oldSha256`,
`newSha256`, `oldSize`, `newSize`, with `null` for the missing side. Entries
are stably sorted by `oldPath` (nulls last), then `newPath`, then `kind`, in
UTF-8 byte order. Identical directories produce `[]`.

If any file is unreadable, vanishes, or changes size or modification time
while being read, stdout stays empty, the affected paths are reported to
stderr in stable path order, and the exit status is 74.
