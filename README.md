# Mac Project Vault

A command-line entry point for working with local project materials on macOS.

Requires macOS 13 or newer and Swift 6. No external dependencies.

```sh
swift build
.build/debug/macvault --help
.build/debug/macvault --version
.build/debug/macvault compare OLD NEW
.build/debug/macvault history-add ROOT P V SNAPSHOT
.build/debug/macvault history-query ROOT [P [V [PATH]]]
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

## `macvault history-add ROOT P V SNAPSHOT`

Registers `SNAPSHOT` in the history store rooted at `ROOT` under project `P`
and version `V`. `P` and `V` must be single path segments that the snapshot
path rules allow (non-empty, no `/`, not `.`/`..`, no NUL bytes); invalid
arguments exit with status 64, as does a `ROOT` that exists but is not a
directory. `SNAPSHOT` is decoded with the same strict validation as
`snapshot-diff`; an unreadable or invalid snapshot exits with status 65.

The record stores `P`, `V`, the snapshot's absolute path, the SHA-256 of its
bytes, and its file manifest. A missing or empty `ROOT` is initialized first:
the marker `ROOT/history.json` is published with exactly the structure
`{"version":1}`. A non-empty `ROOT` without that marker, or with a marker of
any other structure, is corrupt and exits with status 65.

Records are staged inside `ROOT` and published atomically, so concurrent
registrations of the same `P`/`V` key let exactly one value win. Re-adding an
identical registration (same `P`/`V`, snapshot path, and hash) is an
idempotent success; the same key with a different path or hash reports an
error and exits with status 73, leaving no new record behind. I/O failures
exit with status 74. On every failure stdout stays empty, an error is written
to stderr, the store is not modified, and staging files are removed.

## `macvault history-query ROOT [P [V [PATH]]]`

Prints the records in the history store `ROOT` that match the optional
filters as a single JSON array on stdout: `P` restricts to one project, `V`
to one version, and `PATH` (a snapshot-relative path) to versions whose
manifest contains that path. The command is read-only: a missing or empty
`ROOT` prints `[]`, exits 0, and creates nothing. A `ROOT` that is not a
directory exits 64; a corrupt store (missing or invalid marker, undecodable
record) exits 65; I/O failures exit 74.

Each array item has exactly the keys `project`, `version`, `snapshotPath`,
`snapshotSha256`, `snapshotStatus`, and `files`, where `files` are the
snapshot's own entries. `snapshotStatus` re-hashes the registered snapshot
file: `intact` when the bytes still match, `modified` when they differ, and
`missing` when the file is gone. Items are sorted by `project` then `version`
and files by `path`, all in UTF-8 byte order. No matches print `[]`.

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
