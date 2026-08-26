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
| `--no-context` | Suppress all discovered `CLAUDE.md`/`CLAUDE.local.md`/`.claude/CLAUDE.md`/`.claude/rules/` files: those in every ancestor directory of the cwd (loaded at launch), those in every subdirectory of the cwd (loaded on demand when Claude reads files there), and `~/.claude/`. |
| `--settings <json-or-file>` | Extra settings to merge in, same shape as `claude --settings`. claude-with's own generated keys (`enabledPlugins`, `claudeMdExcludes`) win over this base. |
| `--dry-run` | Print the generated settings JSON and the exact `claude` command; run nothing. |
| `--` | Everything after this is passed to `claude` verbatim (e.g. `-p`, `--model`, a prompt). |
| `-h`, `--help` | Show help. |
| `-v`, `--version` | Show version. |

`claude-with doctor` checks this machine's plugin setup instead of
launching anything; see [Doctor](#doctor) below.

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
  everything. Precedence: enabling always wins over disabling, regardless
  of flag order. `--plugin x --no-plugin x` leaves `x` enabled, and
  `--only-plugins a@m --no-plugin a@m` leaves `a@m` enabled, because the
  disable set is applied first and the enable set on top of it.

  For every plugin id that ends up *enabled* (from `--plugin` or from
  `--only-plugins`' keep set), claude-with additionally resolves that
  plugin to an on-disk directory and passes it to `claude` as
  `--plugin-dir <dir>`, alongside the `enabledPlugins` entry. This is
  what makes `--plugin` actually load the plugin's content even when
  `~/.claude/plugins/known_marketplaces.json`'s `installLocation` for its
  marketplace is missing, stale, or points at a path from another machine
  (a real, observed failure mode: `installLocation` recorded a Linux path
  after a dotfiles-portability change, Claude Code logged
  `Marketplace <name> failed to load: cache-miss`, and the plugin loaded
  0 language servers even though the marketplace's actual content sat at
  the correct path on disk). Resolution ignores the registry entirely and
  instead reads the marketplace's own
  `~/.claude/plugins/marketplaces/<marketplace>/.claude-plugin/marketplace.json`
  directly, finds the named plugin's `source` field, and resolves it
  relative to the marketplace root:
  - If the resolved directory already has its own
    `.claude-plugin/plugin.json`, that directory is passed to
    `--plugin-dir` as-is.
  - If it doesn't -- some marketplace entries (LSP plugins in particular)
    carry their whole manifest inline in `marketplace.json` instead of a
    separate `plugin.json` file -- claude-with warns on stderr and
    synthesizes one: a temp directory of symlinks to the plugin's files,
    plus a `.claude-plugin/plugin.json` written from that marketplace
    entry (minus the marketplace-only `source`/`category` fields). The
    temp directory is removed when the `claude` process exits (left in
    place only after a successful `--dry-run`, same as claude-with's
    other temp files).
  - If the plugin's `source` is a remote reference (e.g. `git-subdir`)
    rather than a local path, or the plugin/marketplace isn't found on
    disk at all, resolution fails and claude-with exits non-zero naming
    the reason -- see [Doctor](#doctor) and
    [Limitations](#limitations).
  - `--no-plugin` never needs resolution, since disabling a plugin
    doesn't require loading its content.
- **`--no-context`** and **`--context`** compute every
  `CLAUDE.md`/`CLAUDE.local.md`/`.claude/CLAUDE.md`/`.claude/rules/**`
  path that Claude Code would normally discover (every ancestor directory
  of your cwd, every subdirectory of your cwd via `<cwd>/**/...` globs,
  plus `~/.claude/`) and puts them all in
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

## Doctor

Every invocation runs a lightweight preflight and prints warnings to
stderr (never blocking the launch, except when a requested `--plugin` or
`--only-plugins` id can't be resolved to any on-disk directory at all --
see above) for:

- the plugin registry (`~/.claude/plugins/known_marketplaces.json`)
  being missing;
- any marketplace in that registry whose `installLocation` doesn't exist
  on disk;
- the `claude` binary not being on `PATH`.

`claude-with doctor` runs the same checks standalone and prints every one
of them as `[OK]`/`[WARN]`/`[FAIL]`, without launching anything:

```
$ claude-with doctor
[OK]   claude binary on PATH (/usr/local/bin/claude)
[OK]   python3 on PATH (/usr/bin/python3)
[OK]   plugin registry found: /Users/you/.claude/plugins/known_marketplaces.json
[OK]   marketplaces directory found: /Users/you/.claude/plugins/marketplaces
[OK]   marketplace 'claude-plugins-official': installLocation exists (...)
[WARN] marketplace 'trailofbits': installLocation does not exist: /home/other-user/.claude/plugins/marketplaces/trailofbits (on-disk content found at the expected marketplace path anyway)

doctor: no FAILs (see WARNs above for anything that needs attention)
```

Exit code is `1` if any check is `[FAIL]` (currently: `claude` or
`python3` missing from `PATH`, or a registry file that exists but is not
a parseable JSON object), `0` otherwise -- `[WARN]` never affects
the exit code, since a stale `installLocation` doesn't stop `--plugin`
from working (claude-with resolves plugins from the on-disk marketplace
content, not the registry). Doctor never writes anything under
`~/.claude`; every check is read-only.

Point doctor (and every other command) at a different plugins directory
with `CLAUDE_WITH_PLUGINS_HOME` (defaults to `~/.claude/plugins`) -- this
is what the test suite uses to exercise fixture marketplaces instead of
a developer's real `~/.claude`.

## Verified behavior

Verified against **Claude Code v2.1.241** on macOS 15.5, by actually
running `claude` (not just reading `--help` or the docs) for each
mechanism below:

- `claude --settings <file>` with `claudeMdExcludes` reliably suppresses
  the listed `CLAUDE.md` file. Confirmed working.
- `**` glob entries in `claudeMdExcludes` suppress `.claude/rules/` files
  and subdirectory `CLAUDE.md` files. Test setup: a temp cwd containing
  `.claude/rules/secret.md` (instructing "reply QUARTZ") and
  `sub/deep/CLAUDE.md` (instructing "reply GRANITE"); the prompt made
  Claude read `sub/deep/notes.txt` to trigger subdirectory discovery,
  then asked for both words. With only `~/.claude/` excluded the answer
  was `SECRET=QUARTZ SUB=GRANITE`. With `<cwd>/.claude/rules/**`,
  `<cwd>/**/CLAUDE.md`, `<cwd>/**/.claude/rules/**` (and the other
  subtree globs claude-with emits) added, the answer was
  `SECRET=UNKNOWN SUB=UNKNOWN`. Both globs were present in the same run,
  so this shows the rules file and the nested `CLAUDE.md` were suppressed
  by the set, not which single pattern caught the rules file.
- A `claudeMdExcludes` entry matches the path as configured, not its
  symlink target: excluding `~/.claude/CLAUDE.md` suppressed a
  `~/.claude/CLAUDE.md` that is a symlink into a dotfiles repo, while
  excluding only the resolved dotfiles path did not.
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
- **`--plugin`'s `--plugin-dir` fallback fixes a real, observed failure.**
  On a machine where `known_marketplaces.json` recorded
  `installLocation` as a path from a different machine (so Claude Code
  logged `Marketplace claude-plugins-official failed to load: cache-miss`
  and loaded 0 language servers for `typescript-lsp`), plain
  `claude -p ... --settings '{"enabledPlugins":{"typescript-lsp@...":true}}'`
  still showed `Total LSP servers loaded: 0` in its `--debug-file` log.
  `claude-with --plugin typescript-lsp@claude-plugins-official` on the
  same machine resolved the plugin from the on-disk marketplace, warned
  that it had to synthesize a `plugin.json` (this plugin's manifest lives
  only in `marketplace.json`), passed the synthesized directory via
  `--plugin-dir`, and the resulting session's debug log showed
  `Loaded inline plugin from path: typescript-lsp` and
  `Total LSP servers loaded: 1` -- the stale-registry `cache-miss` error
  was still logged (harmless) but no longer prevented the plugin from
  loading.

## Limitations

Documented honestly rather than assumed:

- **`--plugin`/`--only-plugins` resolution only handles a plugin whose
  marketplace.json `source` is a local path** (`"./plugins/foo"`,
  resolved relative to the marketplace root). A plugin whose `source` is
  a remote reference (e.g. `{"source": "git-subdir", ...}`) cannot be
  resolved to a directory this way; claude-with exits non-zero naming the
  plugin and its source type rather than silently falling back to
  `enabledPlugins`-only (which is exactly the mechanism that was already
  proven unreliable). If you hit this, use `--plugin-dir`/`--plugin-url`
  directly via `--` passthrough once you've fetched the plugin some other
  way.
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
  via `--` passthrough instead. Unknown ids hard-fail; see "How each flag
  is implemented".
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
  often; they are named `$TMPDIR/claude-with.*`, so `rm $TMPDIR/claude-with.*` cleans them up).

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
