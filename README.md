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

Recursively collects the regular files below `SOURCE` (symbolic links are not
followed) and writes a JSON snapshot to `SNAPSHOT`. Both are given as paths:
`SOURCE` must be an existing directory, and `SNAPSHOT` must not be located
inside it; invalid arguments write an error to stderr and exit with status
64. `SOURCE` is never modified.

The snapshot document has exactly the top-level keys `version`, `capturedAt`,
and `files`:

```json
{"version":1,"capturedAt":"2026-09-22T12:34:56Z","files":[{"path":"README.md","sha256":"…","size":1234}]}
```

`capturedAt` is the capture time in UTC RFC3339 (`…Z`). Each file entry has
exactly the keys `path`, `sha256`, and `size`; entries are ordered by `path`
in UTF-8 byte order and hashes are lowercase hex SHA-256. Paths are
non-empty relative paths with `/` separators: absolute paths, leading or
trailing slashes, empty segments, and `.`/`..` are invalid. Backslashes are
ordinary characters, standard JSON escaping applies, and Unicode paths are
not normalized (different code-point sequences are different paths).

The snapshot is first written to a hidden staging file in the destination
directory and then published atomically; an existing `SNAPSHOT` is never
overwritten — the program reports an error to stderr and exits with status
73. If any file is unreadable, vanishes, or changes size or modification
time while being read, the staging file is removed, the affected paths are
reported to stderr in stable path order, stdout stays empty, and the exit
status is 74.

## `macvault snapshot-diff SNAPSHOT CURRENT`

Treats `SNAPSHOT` as the old side and `CURRENT` (an existing directory,
collected recursively and read-only without following symbolic links) as the
new side, and prints the same JSON array with the same sorting and difference
semantics as `compare` (including the unique-hash-on-each-side `moved` rule).
Success exits 0 and an identical tree prints `[]`.

A snapshot that cannot be decoded or that violates the format — unsupported
or wrong-typed `version`, missing or extra fields, invalid or duplicate or
out-of-order paths, invalid hashes or sizes — produces no stdout output, an
error on stderr, and exit status 65. The snapshot is never repaired. Failure
while collecting `CURRENT` reports the affected paths and exits with status
74.
