# Mac Project Vault

A command-line utility for receiving local project materials into a vault and
querying the catalog of what was received.

Requires macOS 13 or newer and Swift 6. No external dependencies (uses the
system SQLite library and CryptoKit).

```sh
swift build
.build/debug/macvault --help
```

## Commands

```sh
macvault init --vault <dir>
macvault import --vault <dir> --source <dir> --json
macvault list --vault <dir> --json [--name <substring>]
```

- `init` creates `<vault>/catalog.sqlite3` and `<vault>/objects`. Running it
  again is safe and never deletes existing data.
- `import` recursively receives regular files from `<source>`. Each file's
  content is identified by the SHA-256 of its bytes and stored once per hash
  at `objects/<sha256>`. Re-importing the same path with the same content is
  a no-op; the same content at a different path adds another catalog entry
  that reuses the stored object. Entries are preflighted, staged into a
  temporary area, and committed through a database transaction, so a failed
  import leaves the vault untouched and leaves no temporary files. Symbolic
  links, non-regular files, unreadable files, and paths escaping the source
  directory are rejected with the offending relative path on stderr. The JSON
  result reports `imported`, `unchanged`, and `reusedObjects` counts.
- `list` prints the catalog as a JSON array of
  `{id, relativePath, sha256, size}` objects ordered by `relativePath`, then
  `id`. `--name` filters on the file name with a case-insensitive substring
  match; an empty result prints `[]`.

No arguments, `-h`, or `--help` print usage; `--version` prints the version.

## Exit codes

- `0` — success
- `1` — runtime error (missing or uninitialized vault, missing source,
  rejected or unreadable entry, commit failure); details go to stderr
- `64` — usage error (unknown option or command, missing or conflicting
  arguments); details go to stderr
