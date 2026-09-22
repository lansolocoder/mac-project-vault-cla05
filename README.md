# Mac Project Vault

A command-line entry point for working with local project materials on macOS.

Requires macOS 13 or newer and Swift 6. No external dependencies; storage uses
the system SQLite library and content is identified by SHA-256.

```sh
swift build
.build/debug/macvault --help
.build/debug/macvault --version
```

## Commands

### Initialize a vault

```sh
macvault init --vault <dir>
```

Creates `<vault>/catalog.sqlite3` and `<vault>/objects`. Re-running `init` on
an existing vault is safe and never clears data.

### Import a source tree

```sh
macvault import --vault <dir> --source <dir> --json
```

Recursively receives the regular files under `--source`. Each distinct content
is stored exactly once as `objects/<sha256>`; catalog entries keep their own
paths and share objects. Re-importing the same tree is idempotent: entries
whose path and hash are unchanged are counted as `unchanged`.

Output example:

```json
{"imported":2,"reusedObjects":1,"unchanged":3}
```

Imports are atomic. Every entry is inspected and hashed before anything is
written; new blobs first land in a private staging directory and are published
while the catalog is updated in one transaction. Symbolic links, non-regular
or unreadable files, path escape attempts, and commit failures abort the whole
import (exit code `1`), leave the previous state intact, and remove all
temporary files. The offending entry's path, relative to the source root, is
reported on stderr.

### List catalog entries

```sh
macvault list --vault <dir> --json [--name <substring>]
```

Prints a JSON array of catalog entries sorted by `relativePath` and then `id`:

```json
[{"id":1,"relativePath":"docs/notes.md","sha256":"…","size":412}]
```

`--name` filters by case-insensitive substring match against the file name
(not the full path). No matches produce `[]`.

## Exit codes

- `0` — success
- `1` — runtime failure (vault missing or uninitialized, rejected entry,
  commit failure); the message goes to stderr
- `64` — usage error (unknown command/option, missing option value,
  duplicate or conflicting options)

With no arguments, or with `-h`/`--help`, the program prints help;
`--version` prints the version.
