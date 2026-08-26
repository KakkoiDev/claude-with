# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Test: `./test_claude_with.sh`. Plain assertion helpers, no framework, no login, no real `claude` session (asserts against `--dry-run` output only). See README.md's "Verified behavior" section for real-invocation findings.
- `claude --settings '<inline-json>'` does not reliably apply `claudeMdExcludes` (verified empirically on v2.1.241); `claude --settings <file>` with the same JSON does. `claude-with` always writes settings to a temp file for this reason. Re-verify against the current `claude --help` and a real invocation before assuming this changed.
- `--append-system-prompt-file` and `--system-prompt-file` are undocumented in `claude --help` (only referenced inside the `--bare` flag's own description text) but work as of v2.1.241. Watch for removal/rename in future releases.
- Must stay bash 3.2 compatible (macOS stock `/bin/bash`). Avoid `${arr[@]:-}` under `set -u` on a possibly-empty array; it expands to one spurious empty-string element. Guard with `[ "${#arr[@]}" -gt 0 ]` before expanding.
- `--plugin`/`--only-plugins` resolve a plugin's on-disk directory from `~/.claude/plugins/marketplaces/<marketplace>/.claude-plugin/marketplace.json` (never the registry's `installLocation`, which is what goes stale across machines) and pass it via `--plugin-dir`. Some marketplace entries (e.g. `typescript-lsp`) carry their whole manifest inline in `marketplace.json` with no `.claude-plugin/plugin.json` in the plugin's own directory; `claude-with` detects that and synthesizes one in a temp dir of symlinks; otherwise `--plugin-dir` would point at a directory with no manifest and the plugin's declarations (e.g. `lspServers`) would be silently dropped. See README's "How each flag is implemented" and "Verified behavior" for the empirical trace. `CLAUDE_WITH_PLUGINS_HOME` (default `~/.claude/plugins`) overrides where this and `doctor` look, so tests never touch the real `~/.claude`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
