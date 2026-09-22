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
.build/debug/macvault history-add ROOT P V SNAPSHOT
.build/debug/macvault history-query ROOT [P [V [PATH]]]
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

## `macvault history-add ROOT P V SNAPSHOT`

Registers `SNAPSHOT` in the history rooted at `ROOT` under project `P` and
version `V`. `P` and `V` must be single path segments that satisfy the
snapshot path rules; identification and ordering use raw UTF-8 bytes. The
snapshot is strictly decoded with the same rules as `snapshot-diff`
(invalid snapshots exit 65), and the record stores `P`, `V`, the snapshot's
absolute path, the SHA-256 of its bytes, and the file manifest.

A missing or empty `ROOT` is initialized on demand: a marker file
`ROOT/history.json` containing exactly `{"version":1}` is published and
records are kept under `ROOT/records/`. A non-empty `ROOT` without the
marker, or with a marker that is not exactly that structure, is corrupt and
exits 65; a `ROOT` that exists but is not a directory exits 64.

If a record for the same `P`/`V` already exists with the same snapshot path
and hash, the add is idempotent and succeeds; a different path or hash exits
73. Records are staged inside `ROOT` and published atomically, so concurrent
adds for the same key let exactly one value win and a failed add leaves no
new record behind. I/O failures exit 74; on every failure stdout stays
empty, an error goes to stderr, and staging files are removed.

## `macvault history-query ROOT [P [V [PATH]]]`

Prints the registered history as a single JSON array on stdout, read-only. A
missing or empty `ROOT` prints `[]`, exits 0, and creates nothing. The
optional filters select a project `P`, a version `V`, and — with `PATH`, a
snapshot relative path — only versions whose manifest contains that path.

Each array item has exactly the keys `project`, `version`, `snapshotPath`,
`snapshotSha256`, `snapshotStatus`, and `files` (the snapshot entries).
Records are ordered by project and version, files by path, all in UTF-8 byte
order. `snapshotStatus` is `intact`, `modified`, or `missing`, depending on
whether the snapshot file still exists with the recorded hash. No matches
print `[]`. Invalid arguments exit 64, corrupt `ROOT` state exits 65, and
I/O failures exit 74.
