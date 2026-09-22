# Mac Project Vault

A command-line entry point for working with local project materials on macOS.

Requires macOS 13 or newer and Swift 6. No external dependencies.

```sh
swift build
.build/debug/macvault --help
.build/debug/macvault --version
.build/debug/macvault compare OLD NEW
.build/debug/macvault snapshot SOURCE SNAPSHOT
.build/debug/macvault snapshot-diff SNAPSHOT CURRENT
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

## `macvault snapshot SOURCE SNAPSHOT`

Recursively captures the regular files in SOURCE into a new JSON snapshot
file. SOURCE must be an existing directory. Symbolic links are not followed.
Relative paths use `/` separators, are non-empty and contain no `.` or `..`
segments; backslashes are ordinary characters and Unicode is never
normalized. Files are ordered by the UTF-8 bytes of their paths and recorded
with `path`, lowercase `sha256` and `size`.

The document has exactly the top-level keys `version` (always `1`),
`capturedAt` (the capture time in UTC RFC 3339) and `files`. The snapshot is
staged next to its final name and published atomically.

SNAPSHOT must not already exist and must not be located inside SOURCE
(symlinks are resolved when checking). If SOURCE is not a directory or
SNAPSHOT is inside SOURCE the exit status is 64. If SNAPSHOT already exists
it is never overwritten and the exit status is 73. If any file is
unreadable, vanishes, or changes size or modification time while being read,
staging is cleaned up, SOURCE is left untouched and the exit status is 74.

## `macvault snapshot-diff SNAPSHOT CURRENT`

Treats SNAPSHOT as the old side and CURRENT (an existing directory, captured
read-only with the same rules as `compare`) as the new side, then prints the
same JSON array using the same difference and ordering semantics as
`compare`, including unique-on-each-side `moved` detection.

The snapshot must decode strictly: malformed JSON, an unsupported version,
missing or extra top-level or file fields, invalid or duplicate paths,
invalid hashes or sizes, or out-of-order file entries all leave stdout
empty, write an error to stderr and exit with status 65 without repairing
the snapshot. Failure while collecting CURRENT exits 74. An identical
CURRENT directory produces `[]` and exit status 0.
