# claude-with

Launch [Claude Code](https://claude.com/product/claude-code) with exactly
the plugins, settings, and context you choose, per invocation, without
touching any persistent config file.

```
claude-with --no-plugin typescript-lsp@claude-plugins-official
claude-with --plugin x@marketplace --context docs/onboarding.md
claude-with --only-plugins security-review@claude-plugins-official
```

No daemon. No config file. Every flag is translated into `claude` CLI
flags and a generated `--settings` file for that one process; nothing is
written to `~/.claude/` or any project's `.claude/`.

## Why not hps?

[harness-profile-switcher (hps)](https://github.com/KakkoiDev/harness-profile-switcher)
and claude-with solve different problems and are meant to be used together:

- **hps** owns *persistent, user-level profiles*: it switches which whole
  `~/.claude/` config (agents, skills, plugins, commands, hooks) is active
  on your machine, so the change survives across every future session
  until you switch again.
- **claude-with** owns *per-invocation launch config*: it never touches
  `~/.claude/` or your project's `.claude/`. Every flag applies only to the
  one `claude` process it starts; run it again with no flags and you're
  back to your normal setup.

Use hps when you want "for the next while, I am the frontend profile."
Use claude-with when you want "for just this one session, turn this
plugin off" or "load this file instead of CLAUDE.md."

## Install

```
git clone https://github.com/KakkoiDev/claude-with.git
cd claude-with
./install.sh
```

Or, once published:

```
curl -fsSL https://raw.githubusercontent.com/KakkoiDev/claude-with/main/install.sh | sh
```

Requires `bash` (3.2+, i.e. macOS's stock `/bin/bash` is fine) and
`python3` (used to build/merge the generated settings JSON, the same
dependency hps already requires).

## Usage

```
claude-with [OPTIONS] [-- CLAUDE_ARGS...]
```

| Flag | Effect |
| --- | --- |
| `--plugin <name>` | Enable a plugin for this session only (repeatable). `name` is the exact plugin id, e.g. `typescript-lsp@claude-plugins-official`. |
| `--no-plugin <name>` | Disable a plugin for this session only (repeatable). |
| `--only-plugins <a,b,c>` | Disable every other *installed* plugin, keeping only the ones listed. Errors out (naming every offending id) if any listed id is not installed. See [Limitations](#limitations). |
| `--context <file-or-dir>` | Load this file or directory instead of discovered `CLAUDE.md` files (repeatable). |
| `--no-context` | Suppress all discovered `CLAUDE.md`/`CLAUDE.local.md`/`.claude/rules/` files. |
| `--settings <json-or-file>` | Extra settings to merge in, same shape as `claude --settings`. claude-with's own generated keys (`enabledPlugins`, `claudeMdExcludes`) win over this base. |
| `--dry-run` | Print the generated settings JSON and the exact `claude` command; run nothing. |
| `--` | Everything after this is passed to `claude` verbatim (e.g. `-p`, `--model`, a prompt). |
| `-h`, `--help` | Show help. |
| `-v`, `--version` | Show version. |

### Examples

Turn the TypeScript LSP plugin off for one session:

```
claude-with --no-plugin typescript-lsp@claude-plugins-official
```

Turn it back on for one session; elsewhere it stays off by default:

```
claude-with --plugin typescript-lsp@claude-plugins-official
```

Load a specific onboarding doc instead of whatever `CLAUDE.md` files this
directory tree would normally discover:

```
claude-with --context docs/onboarding.md
```

Strip all context and pass a prompt straight through:

```
claude-with --no-context -- -p "explain this repo from a cold start"
```

See exactly what would run, without running it:

```
claude-with --dry-run --no-plugin typescript-lsp@claude-plugins-official
```

## How each flag is implemented

- **`--plugin` / `--no-plugin` / `--only-plugins`** set
  [`enabledPlugins`](https://code.claude.com/docs/en/settings-reference)
  (`{"plugin-id": true|false}`) in a generated settings file passed via
  `claude --settings <file>`. `--only-plugins` first runs
  `claude plugin list --json` to enumerate every currently installed
  plugin, then sets every id not in your list to `false`. If any id you
  listed is not among the installed ones (e.g. a typo), claude-with exits
  with an error naming every missing id instead of silently disabling
  everything.
- **`--no-context`** and **`--context`** compute every
  `CLAUDE.md`/`CLAUDE.local.md`/`.claude/CLAUDE.md`/`.claude/rules/**`
  path that Claude Code would normally discover (every ancestor directory
  of your cwd, plus `~/.claude/`) and puts them all in
  [`claudeMdExcludes`](https://code.claude.com/docs/en/memory#exclude-specific-claude-md-files).
  `--context <path>` additionally passes that file's content (or, for a
  directory, its top-level `*.md`/`*.txt` files concatenated into one temp
  file) via `--append-system-prompt-file`.

  We picked `--append-system-prompt-file` over the `--add-dir` +
  `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` mechanism because the
  latter only loads files literally named `CLAUDE.md`, `CLAUDE.local.md`,
  or `.claude/rules/*.md` inside the added directory. It cannot load an
  arbitrarily named file like `z.md`. `--append-system-prompt-file` works
  for any file, at the cost of the content landing in the system prompt
  rather than as a discoverable memory file.
- **`--settings`** is merged with claude-with's own generated keys using
  `python3`, then always written to a temp file (see "Verified behavior"
  below for why), passed as `claude --settings <file>`.
- **`--dry-run`** just prints the generated JSON and the assembled
  `claude` command instead of running it. This is also the test seam:
  `test_claude_with.sh` asserts against `--dry-run` output for every flag
  combination, without ever starting a real session.

## Verified behavior

Verified against **Claude Code v2.1.241** on macOS 15.5, by actually
running `claude` (not just reading `--help` or the docs) for each
mechanism below:

- `claude --settings <file>` with `claudeMdExcludes` reliably suppresses
  the listed `CLAUDE.md` file. Confirmed working.
- `claude --settings '<inline-json>'` (the JSON passed as a literal
  command-line string, not a file) did not reliably apply
  `claudeMdExcludes` in repeated tests: a `CLAUDE.md` targeted by an
  exact-path exclude still loaded. Writing the identical JSON to a file
  and passing `--settings <file>` fixed it every time. This is why
  claude-with always writes settings to a temp file, even for a one-line
  JSON blob, rather than passing the JSON inline as the docs' own
  examples suggest you could.
- `--append-system-prompt-file <path>` (undocumented in `claude --help`;
  it only appears inside the `--bare` flag's own description text, not as
  its own listed option) works: the file's content reaches the model via
  the system prompt.
- `--add-dir <dir>` with `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`
  does load a `CLAUDE.md` from the added directory that wouldn't
  otherwise be discovered.
- `claude plugin list --json` returns installed plugin ids, enabling
  `--only-plugins` to enumerate what to disable.
- `--dry-run` is not a real `claude` flag (`claude` itself errors with
  `unknown option '--dry-run'`), so claude-with can safely intercept it
  without ever forwarding it.

## Limitations

Documented honestly rather than assumed:

- **`enabledPlugins`'s runtime effect was not independently confirmed
  end to end.** We confirmed the JSON is generated correctly and applies
  without error via a settings file, matching the documented schema. We
  could not confirm in this environment that a plugin actually disappears
  from the session's available skills or tools when set to `false`,
  because every plugin installed in the test environment was either
  already disabled or already failing to load from its marketplace (a
  `cache-miss` unrelated to claude-with). Verify with `claude plugin list`
  or `/context` in your own environment if this matters to you.
- **`--no-context` / `--context` do not suppress auto memory.** Auto
  memory (`~/.claude/projects/<project>/memory/MEMORY.md`) is a separate
  system from `CLAUDE.md` and is not covered by `claudeMdExcludes`. If
  Claude has previously recorded a preference in auto memory for this
  project, it can still surface even with `--no-context`.
- **Managed policy `CLAUDE.md` cannot be excluded**, by design. This is
  documented Claude Code behavior (`claudeMdExcludes` explicitly does not
  apply to the managed-policy file), not something claude-with can work
  around.
- **`--only-plugins` disables based on what `claude plugin list --json`
  reports as installed**, which is a per-machine, persistent list (what
  hps or `claude plugin install` put there). claude-with cannot discover
  or enable a plugin that isn't installed anywhere on the machine; it can
  only toggle installed ones on or off for this session. If you wanted to
  provision an entirely new plugin per invocation with no prior
  `claude plugin install`, use `--plugin-dir` or `--plugin-url` directly
  via `--` passthrough instead. If an id passed to `--only-plugins` is
  not in the installed list, claude-with hard-fails with an error naming
  every missing id rather than silently ignoring it.
- **`--context` on a directory is not recursive and only picks up
  `*.md`/`*.txt` files, one level deep.** This is a design simplification,
  not a `claude` limitation; pass a specific file if you need something
  else included.
- **`--append-system-prompt-file` is undocumented** in `claude --help` on
  the tested version. It works today; if a future Claude Code release
  removes or renames it, `--context` breaks. There is no long-term stable
  alternative that handles arbitrary filenames the way this one does.
- The temp files claude-with generates (the `--settings` file, plus one
  concatenated file per `--context <dir>`) are deleted when the underlying
  `claude` process exits (claude-with runs `claude` as a child process,
  not via `exec`, precisely so its cleanup trap can fire afterwards);
  under `--dry-run` they are deliberately
  left on disk so the printed command is actually runnable if copy-pasted
  (it will accumulate harmless files in `$TMPDIR` if you run `--dry-run`
  often; clean up `$TMPDIR/tmp.*` yourself if that bothers you).

## Testing

```
./test_claude_with.sh
```

Plain shell assertions (`assert_eq`/`assert_contains`/`assert_exit`),
mirroring hps's `test_hps.sh`: no framework, no login, no real `claude`
session started. Every flag combination is exercised against `--dry-run`
output; the two acceptance-criteria commands from the launch brief are
asserted verbatim as their own test cases.

## License

MIT, see [LICENSE](LICENSE).
