# setlint

Linter for a Claude Code `settings.json` / `settings.local.json`.

Claude Code reads its behavior from settings files — the project
`.claude/settings.json` and `.claude/settings.local.json`, and the
user-level `~/.claude/settings.json`. The highest-stakes thing those
files do is wire **hooks**: a `PreToolUse` or `PostToolUse` entry whose
`command` string is run before or after a tool call. A `PreToolUse`
hook is often a *guardrail* — it can deny a dangerous command, or
require approval before a publish or a push.

The failure mode that matters: if a hook's `command` does not resolve
to a file that exists and is executable, **the hook silently never
runs.** No error, no warning — the tool call just proceeds as if the
hook were never configured. A guardrail you believe is protecting you
is not. This happens for ordinary reasons: the hook script gets moved,
a refactor renames `.claude/hooks/`, a fresh clone drops the executable
bit, an absolute path is copied between machines.

[`hookprobe`](https://github.com/kVadrum/hookprobe) *runs* a hook with
synthetic input to test its decision logic. `setlint` is the other
half: it checks that a settings file actually *connects* a hook in the
first place.

Python 3, standard library only — no `jq`, no third-party dependencies.

## Background

setlint was conceived and written by Claude in claude-expo — a private
workshop where Claude picks and builds small utilities under operator
oversight. Correctness- and security-sensitive changes get a
cross-vendor second read from Codex (OpenAI's GPT) before they land. It
is the settings-file half of a pair with
[`hookprobe`](https://github.com/kVadrum/hookprobe); more on the
workshop in
[claude-journal](https://github.com/kVadrum/claude-journal).

## Usage

```
setlint [PATH]              lint settings at PATH (default: .)
setlint --project-dir DIR   resolve $CLAUDE_PROJECT_DIR to DIR
setlint --json              emit findings as a single JSON document
setlint --ci                emit GitHub Actions workflow-command annotations
setlint --strict            treat warnings as errors (affects exit code)
setlint --quiet             suppress the "clean" line; print findings only
setlint --version           print version
setlint -h | --help         show help
```

`PATH` may be a settings JSON file directly, or a directory. For a
directory, setlint discovers `.claude/settings.json`,
`.claude/settings.local.json`, `settings.json`, and
`settings.local.json` beneath it and lints each that exists.

### `$CLAUDE_PROJECT_DIR` resolution

A hook command frequently references the project root as
`$CLAUDE_PROJECT_DIR` — the variable Claude Code injects when it runs
the hook. setlint resolves it the same way: to the directory
containing the `.claude/` that holds the settings file (or to
`--project-dir` if you pass one). So a command like

```json
"command": "$CLAUDE_PROJECT_DIR/.claude/hooks/guardrails.sh"
```

is checked against the real file on disk, not skipped. `$HOME` and a
leading `~/` are resolved too.

## Checks

Errors fail the lint (exit 2). Warnings are advisory (exit 1) unless
`--strict` promotes them.

| level | check | meaning |
|-------|-------|---------|
| error | `invalid-json` | file is not parseable JSON (Claude Code silently falls back to defaults) |
| error | `not-utf8` | file is not valid UTF-8 |
| error | `not-an-object` | top-level JSON is not an object |
| error | `unreadable` | the file could not be read |
| error | `hooks-not-object` | `hooks` is present but not an object |
| error | `hook-event-not-array` | a `hooks.<Event>` value is not an array |
| error | `hook-entry-not-object` | a matcher entry is not an object |
| error | `hook-entry-no-hooks` | an entry has `command`/`type` but no nested `hooks` array — it never runs |
| error | `hooks-not-array` | an entry's `hooks` is not an array |
| error | `hook-not-object` | a hook is not an object |
| error | `hook-type-missing` | a hook has no `type` |
| error | `hook-type-unknown` | a hook's `type` is not `command` |
| error | `hook-command-none` | a command hook has no `command` field |
| error | `hook-command-not-string` | `command` is not a string |
| error | `hook-command-empty` | a `command` hook has an empty command |
| error | `hook-command-missing` | resolved command path does not exist |
| error | `hook-command-not-exec` | resolved command path exists but is not executable |
| error | `matcher-not-string` | a `matcher` is not a string |
| error | `matcher-invalid-regex` | a `matcher` is not a valid regex (`*` and `""` match-all are allowed) |
| error | `permissions-not-object` | `permissions` is not an object |
| error | `permission-list-not-array` | `allow`/`ask`/`deny`/`additionalDirectories` is not an array |
| error | `permission-rule-not-string` | a permission rule is not a string |
| error | `default-mode-not-string` | `permissions.defaultMode` is not a string |
| error | `env-not-object` | `env` is not an object |
| error | `env-value-not-string` | an `env` value is not a string |
| warn | `unknown-key` | unrecognized top-level key |
| warn | `key-typo` | top-level key looks like a misspelling of a known one |
| warn | `misplaced-permission-key` | top-level `allow`/`ask`/`deny` belongs under `permissions` |
| warn | `hook-event-unknown` | a `hooks` key is not a known event (a newer event may have shipped) |
| warn | `matcher-ignored` | a `matcher` on an event with nothing to match (`Stop`, `UserPromptSubmit`) |
| warn | `hooks-empty` | an entry's `hooks` array is empty |
| warn | `hook-command-complex` | command is a pipeline/compound; not statically checked |
| warn | `hook-command-unresolved` | command has an unresolved `$VAR`; cannot verify |
| warn | `hook-command-not-on-path` | bare command not found on `PATH` at lint time |
| warn | `default-mode-unknown` | `permissions.defaultMode` is not a recognized mode |

## Requirements, not permissions

A settings file has *requirements* (the `command` field must be a
string; `hooks` must be an object) and it has *permissions* (a command
*may* be a shell pipeline; a path *may* be resolved from an environment
variable known only at runtime). A linter's job is to enforce the
requirements and to deliberately **not** police the permissions —
otherwise it fires on correct configuration and you learn to ignore it.

So setlint asserts only what it can actually resolve:

- A command with an **unresolved variable** (anything other than
  `$CLAUDE_PROJECT_DIR` / `$HOME`) is a *warning*, not an error. The
  path may be perfectly valid at runtime; setlint just can't see it.
- A command that is a **shell pipeline or compound** (`|`, `&&`, `;`,
  `$(…)`, …) is a *warning* — the program isn't a single token to stat.
- A **bare command name** resolved off `PATH` is checked against
  lint-time `PATH`; a miss is a *warning*, since the runtime `PATH` may
  differ.

The errors are reserved for wiring that is unambiguously broken: a path
that resolves and points at nothing, or at a file without the execute
bit.

## Output

Default output groups findings by file. `--json` emits one document
(`{version, errors, warnings, findings[]}`) for downstream tools.
`--ci` emits GitHub Actions `::error`/`::warning` workflow commands so
findings annotate a pull request.

```
$ setlint .

.claude/settings.local.json
  ✗ hook-command-missing     hooks.PreToolUse[0].hooks[0]: command path does not exist: …/.claude/hooks/guardrails.sh

1 errors, 0 warnings
```

## Exit codes

- `0` — clean.
- `1` — warnings only.
- `2` — at least one error, `--strict` with warnings, or a usage error.

## Scope and limits

- setlint lints each settings file independently; it does not merge the
  user / project / local precedence chain into the effective config.
- For a command with arguments (`python hook.py`), setlint checks the
  first token (`python`) — it verifies the interpreter, not the script
  argument. Direct script paths are the common case and are fully
  checked.
- A quoted command path (single or double quotes) is taken whole, so a
  quoted path with spaces resolves correctly. An *unquoted* path with
  embedded spaces is not split-aware (first whitespace token wins) —
  rare, and the fix is to quote it.

## Tests

```
tests/run.sh
```

Fixture-driven: each `tests/fixtures/<name>/` is a small settings tree
plus an `expected.txt` of `key=value` assertions (`has.<check>`,
`level.<check>`, `count.<check>`, `absent.<check>`, `errors`, `warnings`)
checked against `setlint --json` by `tests/check.py`. The `not-exec`
fixture commits a mode-644 hook script, so the executable bit is part of
the fixture — preserve it under git. Python 3 only; no network.

## License

MIT — see [`LICENSE`](./LICENSE). "setlint" as a name and the KeMeK
Network identity are not covered by the code license.

---

KeMeK Network © 2026
