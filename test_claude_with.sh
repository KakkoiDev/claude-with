#!/usr/bin/env bash
set -euo pipefail

CW="$(cd "$(dirname "$0")" && pwd)/claude-with"
PASS=0
FAIL=0
TESTS=()

# ============================================================
# Bootstrap
# ============================================================

TMPDIR_ROOT=$(mktemp -d)
export TMPDIR="$TMPDIR_ROOT"

# shellcheck disable=SC2329  # invoked via trap EXIT
cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

# claude-with must never read the real ~/.claude for plugin resolution
# during tests. Point it at an empty fixture home by default; individual
# tests override CLAUDE_WITH_PLUGINS_HOME to a purpose-built fixture when
# they need marketplace content on disk.
EMPTY_PLUGINS_HOME="$TMPDIR_ROOT/empty-plugins-home"
mkdir -p "$EMPTY_PLUGINS_HOME"
export CLAUDE_WITH_PLUGINS_HOME="$EMPTY_PLUGINS_HOME"

# ── Fixture builder: a marketplace with one normally-shaped plugin (its
# ── own .claude-plugin/plugin.json), one "inline manifest" plugin whose
# ── full manifest lives only in marketplace.json (mirrors typescript-lsp
# ── on the machine that motivated this feature), and one remote-sourced
# ── plugin that cannot be resolved to a local directory. ──
make_plugin_fixture() {
    local home="$1"
    local mkt_root="$home/marketplaces/goodmarket"
    mkdir -p "$mkt_root/.claude-plugin"
    mkdir -p "$mkt_root/plugins/normal-plugin/.claude-plugin"
    mkdir -p "$mkt_root/plugins/inline-plugin"

    cat > "$mkt_root/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "goodmarket",
  "plugins": [
    {"name": "normal-plugin", "description": "has its own plugin.json", "source": "./plugins/normal-plugin"},
    {"name": "inline-plugin", "description": "manifest lives only in marketplace.json", "version": "1.0.0", "lspServers": {"x": {"command": "x"}}, "source": "./plugins/inline-plugin"},
    {"name": "remote-plugin", "description": "not locally resolvable", "source": {"source": "git-subdir", "url": "https://example.com/x.git", "path": "p"}}
  ]
}
EOF
    printf '{"name":"normal-plugin","description":"d"}\n' > "$mkt_root/plugins/normal-plugin/.claude-plugin/plugin.json"
    echo "readme" > "$mkt_root/plugins/inline-plugin/README.md"

    mkdir -p "$home"
    cat > "$home/known_marketplaces.json" <<EOF
{
  "goodmarket": {"installLocation": "$mkt_root", "lastUpdated": "x"},
  "staleloc": {"installLocation": "/nonexistent/path/staleloc-fixture", "lastUpdated": "x"}
}
EOF
}

# ── Assert helpers ────────────────────────────────

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        TESTS+=("  PASS  $label")
    else
        FAIL=$((FAIL + 1))
        TESTS+=("  FAIL  $label")
        TESTS+=("        expected: $expected")
        TESTS+=("        actual:   $actual")
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        TESTS+=("  PASS  $label")
    else
        FAIL=$((FAIL + 1))
        TESTS+=("  FAIL  $label")
        TESTS+=("        expected to contain: $needle")
        TESTS+=("        actual: $haystack")
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        TESTS+=("  FAIL  $label")
        TESTS+=("        expected NOT to contain: $needle")
        TESTS+=("        actual: $haystack")
    else
        PASS=$((PASS + 1))
        TESTS+=("  PASS  $label")
    fi
}

assert_exit() {
    local label="$1" expected_code="$2"
    shift 2
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    assert_eq "$label" "$expected_code" "$actual_code"
}

# Extract the JSON block printed between the two '#' marker lines.
settings_json_of() {
    "$CW" --dry-run "$@" 2>&1 | sed -n '/^# generated settings JSON:$/,/^# claude command:$/p' | sed '1d;$d'
}

command_of() {
    "$CW" --dry-run "$@" 2>&1 | sed -n '/^# claude command:$/,$p' | sed '1d' | sed 's/[[:space:]]*$//'
}

# ============================================================
# Tests
# ============================================================

test_help_and_version() {
    out=$("$CW" --help 2>&1)
    assert_contains "help shows usage" "$out" "Usage: claude-with"

    out=$("$CW" --version 2>&1)
    assert_contains "version prints v-prefixed number" "$out" "claude-with v"
}

test_dry_run_no_flags_is_plain_claude() {
    out=$(command_of)
    assert_eq "no flags -> plain claude command" "claude" "$out"
    json=$(settings_json_of)
    assert_eq "no flags -> empty settings JSON" "{}" "$json"
}

test_no_plugin_disables_exact_plugin() {
    json=$(settings_json_of --no-plugin typescript-lsp@claude-plugins-official)
    assert_contains "no-plugin sets id false" "$json" '"typescript-lsp@claude-plugins-official": false'

    cmd=$(command_of --no-plugin typescript-lsp@claude-plugins-official)
    assert_contains "no-plugin passes --settings to claude" "$cmd" "--settings"
}

test_plugin_enables_exact_plugin() {
    local home="$TMPDIR_ROOT/fixture-plugin-enable"
    make_plugin_fixture "$home"

    json=$(CLAUDE_WITH_PLUGINS_HOME="$home" settings_json_of --plugin normal-plugin@goodmarket)
    assert_contains "plugin sets id true" "$json" '"normal-plugin@goodmarket": true'

    cmd=$(CLAUDE_WITH_PLUGINS_HOME="$home" command_of --plugin normal-plugin@goodmarket)
    assert_contains "plugin resolved to on-disk dir passes --plugin-dir" "$cmd" "--plugin-dir $home/marketplaces/goodmarket/plugins/normal-plugin"
}

test_plugin_and_no_plugin_repeatable() {
    local home="$TMPDIR_ROOT/fixture-plugin-repeatable"
    make_plugin_fixture "$home"
    mkdir -p "$home/marketplaces/m/plugins/a/.claude-plugin" "$home/marketplaces/m/plugins/b/.claude-plugin"
    printf '{"name":"a","description":"d"}\n' > "$home/marketplaces/m/plugins/a/.claude-plugin/plugin.json"
    printf '{"name":"b","description":"d"}\n' > "$home/marketplaces/m/plugins/b/.claude-plugin/plugin.json"
    mkdir -p "$home/marketplaces/m/.claude-plugin"
    cat > "$home/marketplaces/m/.claude-plugin/marketplace.json" <<'EOF'
{"name": "m", "plugins": [
  {"name": "a", "description": "d", "source": "./plugins/a"},
  {"name": "b", "description": "d", "source": "./plugins/b"}
]}
EOF

    json=$(CLAUDE_WITH_PLUGINS_HOME="$home" settings_json_of --plugin a@m --plugin b@m --no-plugin c@m --no-plugin d@m)
    assert_contains "repeatable --plugin a" "$json" '"a@m": true'
    assert_contains "repeatable --plugin b" "$json" '"b@m": true'
    assert_contains "repeatable --no-plugin c" "$json" '"c@m": false'
    assert_contains "repeatable --no-plugin d" "$json" '"d@m": false'
}

test_plugin_resolves_inline_manifest_via_synthesis() {
    local home="$TMPDIR_ROOT/fixture-plugin-inline"
    make_plugin_fixture "$home"

    out=$(CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" --dry-run --plugin inline-plugin@goodmarket 2>&1)
    assert_contains "inline-manifest plugin warns about missing plugin.json" "$out" "has no .claude-plugin/plugin.json"
    assert_contains "inline-manifest plugin still resolves to a --plugin-dir" "$out" "--plugin-dir"
    assert_not_contains "inline-manifest plugin dir is not the bare source dir" "$out" "--plugin-dir $home/marketplaces/goodmarket/plugins/inline-plugin "

    synth_dir=$(printf '%s' "$out" | sed -n 's/.*--plugin-dir \([^ ]*\).*/\1/p')
    manifest=$(cat "$synth_dir/.claude-plugin/plugin.json")
    assert_contains "synthesized plugin.json carries the marketplace entry's fields" "$manifest" '"lspServers"'
    rm -rf "$synth_dir"
}

test_plugin_unresolvable_marketplace_missing_exits_nonzero() {
    rc=0
    out=$(CLAUDE_WITH_PLUGINS_HOME="$EMPTY_PLUGINS_HOME" "$CW" --dry-run --plugin anything@nosuchmarket 2>&1) || rc=$?
    assert_eq "plugin with no on-disk marketplace exits non-zero" "1" "$rc"
    assert_contains "error names the unresolvable marketplace" "$out" "nosuchmarket"
}

test_plugin_unresolvable_name_exits_nonzero() {
    local home="$TMPDIR_ROOT/fixture-plugin-unknown-name"
    make_plugin_fixture "$home"

    rc=0
    out=$(CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" --dry-run --plugin nope@goodmarket 2>&1) || rc=$?
    assert_eq "plugin not present in marketplace.json exits non-zero" "1" "$rc"
    assert_contains "error names the plugin not found in the marketplace" "$out" "not found in marketplace 'goodmarket'"
}

test_plugin_remote_source_unresolvable_exits_nonzero() {
    local home="$TMPDIR_ROOT/fixture-plugin-remote"
    make_plugin_fixture "$home"

    rc=0
    out=$(CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" --dry-run --plugin remote-plugin@goodmarket 2>&1) || rc=$?
    assert_eq "remote-sourced plugin exits non-zero" "1" "$rc"
    assert_contains "error explains the remote source cannot be resolved" "$out" "not a local path"
}

test_no_plugin_does_not_require_resolution() {
    rc=0
    out=$(CLAUDE_WITH_PLUGINS_HOME="$EMPTY_PLUGINS_HOME" "$CW" --dry-run --no-plugin anything@nosuchmarket 2>&1) || rc=$?
    assert_eq "no-plugin never needs on-disk resolution" "0" "$rc"
    assert_contains "no-plugin still disables the id" "$out" '"anything@nosuchmarket": false'
}

test_preflight_warns_stale_installlocation_on_every_invocation() {
    local home="$TMPDIR_ROOT/fixture-preflight"
    make_plugin_fixture "$home"

    out=$(CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" --dry-run 2>&1)
    assert_contains "preflight warns about stale installLocation with no plugin flags" "$out" "marketplace 'staleloc' installLocation does not exist"
}

test_preflight_non_object_registry_warns_and_continues() {
    local home="$TMPDIR_ROOT/fixture-preflight-array-registry"
    mkdir -p "$home"
    echo '[]' > "$home/known_marketplaces.json"

    rc=0
    out=$(CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" --dry-run 2>&1) || rc=$?
    assert_eq "non-object registry does not abort the invocation" "0" "$rc"
    assert_contains "non-object registry produces a warning" "$out" "is not a JSON object"
    assert_contains "non-object registry still reaches the claude command" "$out" "claude"

    rc=0
    out=$(CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" doctor 2>&1) || rc=$?
    assert_eq "doctor exits non-zero on a non-object registry" "1" "$rc"
    assert_contains "doctor reports the non-object registry" "$out" "[FAIL] plugin registry $home/known_marketplaces.json is not a JSON object"
    assert_contains "doctor counts the registry FAIL in its summary" "$out" "doctor: 1 check(s) FAILED"
}

test_doctor_malformed_registry_json_fails() {
    local home="$TMPDIR_ROOT/fixture-doctor-malformed-registry"
    mkdir -p "$home"
    echo '{not json' > "$home/known_marketplaces.json"

    rc=0
    out=$(CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" doctor 2>&1) || rc=$?
    assert_eq "doctor exits non-zero on unparseable registry" "1" "$rc"
    assert_contains "doctor reports the unparseable registry" "$out" "[FAIL] could not read/parse plugin registry"
    assert_contains "doctor counts the parse FAIL in its summary" "$out" "doctor: 1 check(s) FAILED"
}

test_synth_dir_removed_when_later_plugin_fails() {
    local home="$TMPDIR_ROOT/fixture-synth-cleanup"
    make_plugin_fixture "$home"
    local tmp="$TMPDIR_ROOT/synth-cleanup-tmp"
    mkdir -p "$tmp"

    rc=0
    out=$(TMPDIR="$tmp" CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" --plugin inline-plugin@goodmarket --plugin remote-plugin@goodmarket 2>&1) || rc=$?
    assert_eq "second unresolvable plugin exits non-zero" "1" "$rc"
    assert_contains "first plugin was synthesized before the failure" "$out" "synthesizing one"
    leftover=$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'claude-with-plugin.*' | wc -l | tr -d ' ')
    assert_eq "synthesized plugin dir is removed when a later plugin fails" "0" "$leftover"

    local dry_tmp="$TMPDIR_ROOT/synth-cleanup-dry-tmp"
    mkdir -p "$dry_tmp"
    rc=0
    TMPDIR="$dry_tmp" CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" --dry-run --plugin inline-plugin@goodmarket --plugin remote-plugin@goodmarket >/dev/null 2>&1 || rc=$?
    assert_eq "dry-run with a later unresolvable plugin exits non-zero" "1" "$rc"
    leftover=$(find "$dry_tmp" -mindepth 1 -maxdepth 1 -name 'claude-with-plugin.*' | wc -l | tr -d ' ')
    assert_eq "failed dry-run leaves no synthesized plugin dir" "0" "$leftover"
}

test_no_context_excludes_all_discovered_claude_md() {
    json=$(settings_json_of --no-context)
    assert_contains "no-context sets claudeMdExcludes" "$json" '"claudeMdExcludes"'
    assert_contains "no-context excludes cwd CLAUDE.md" "$json" "$(pwd)/CLAUDE.md"
    assert_contains "no-context excludes user CLAUDE.md" "$json" "$HOME/.claude/CLAUDE.md"
}

test_no_context_excludes_subdirectory_claude_md() {
    local cwd="$TMPDIR_ROOT/subtree-cwd"
    mkdir -p "$cwd/packages/api/.claude/rules"
    echo "nested" > "$cwd/packages/api/CLAUDE.md"
    echo "nested rule" > "$cwd/packages/api/.claude/rules/r.md"

    json=$(cd "$cwd" && "$CW" --dry-run --no-context 2>&1 | sed -n '/^# generated settings JSON:$/,/^# claude command:$/p' | sed '1d;$d')
    assert_contains "no-context emits cwd subtree CLAUDE.md glob" "$json" "$cwd/**/CLAUDE.md"
    assert_contains "no-context emits cwd subtree CLAUDE.local.md glob" "$json" "$cwd/**/CLAUDE.local.md"
    assert_contains "no-context emits cwd subtree .claude/CLAUDE.md glob" "$json" "$cwd/**/.claude/CLAUDE.md"
    assert_contains "no-context emits cwd subtree rules glob" "$json" "$cwd/**/.claude/rules/**"

    matched=$(printf '%s' "$json" | CW_TARGET="$cwd/packages/api/CLAUDE.md" CW_RULE="$cwd/packages/api/.claude/rules/r.md" python3 -c '
import json, os, sys, fnmatch
globs = json.load(sys.stdin)["claudeMdExcludes"]
def hit(path):
    return any(fnmatch.fnmatchcase(path, g.replace("**", "*")) for g in globs)
print("md" if hit(os.environ["CW_TARGET"]) else "-", "rule" if hit(os.environ["CW_RULE"]) else "-")
')
    assert_eq "no-context globs match nested CLAUDE.md and nested rules file" "md rule" "$matched"
}

test_context_file_appends_system_prompt_and_excludes_claude_md() {
    ctx="$TMPDIR_ROOT/ctx.md"
    echo "context body" > "$ctx"

    json=$(settings_json_of --context "$ctx")
    assert_contains "context implies claudeMdExcludes" "$json" '"claudeMdExcludes"'

    cmd=$(command_of --context "$ctx")
    assert_contains "context file passed via --append-system-prompt-file" "$cmd" "--append-system-prompt-file $ctx"
}

test_context_dir_concatenates_into_tmpfile() {
    dir="$TMPDIR_ROOT/ctxdir"
    mkdir -p "$dir"
    echo "one" > "$dir/a.md"
    echo "two" > "$dir/b.md"
    echo "ignored" > "$dir/c.bin"

    cmd=$(command_of --context "$dir")
    assert_contains "context dir passed via --append-system-prompt-file" "$cmd" "--append-system-prompt-file"
    assert_not_contains "context dir does not pass the dir path itself" "$cmd" "--append-system-prompt-file $dir "

    tmpfile=$(printf '%s' "$cmd" | sed -n 's/.*--append-system-prompt-file \([^ ]*\).*/\1/p')
    assert_eq "context dir temp file exists" "yes" "$([ -f "$tmpfile" ] && echo yes || echo no)"
    content=$(cat "$tmpfile"; echo x)
    assert_eq "context dir temp file is sorted md/txt content, c.bin excluded" "$(printf 'one\n\n\ntwo\n\n\n'; echo x)" "$content"
    assert_contains "dry-run temp files land under the suite's cleanup root" "$tmpfile" "$TMPDIR_ROOT/"
}

test_context_missing_path_fails() {
    assert_exit "missing --context path exits non-zero" 1 "$CW" --dry-run --context "$TMPDIR_ROOT/does-not-exist"
}

test_only_plugins_requires_claude_on_path() {
    local bin_dir="$TMPDIR_ROOT/no-claude-bin"
    mkdir -p "$bin_dir"
    for tool in bash python3; do
        ln -s "$(command -v "$tool")" "$bin_dir/$tool"
    done

    rc=0
    out=$(PATH="$bin_dir" "$CW" --dry-run --only-plugins foo@bar 2>&1) || rc=$?
    assert_eq "only-plugins without claude on PATH fails" "1" "$rc"
    assert_contains "only-plugins missing-claude error message" "$out" "claude CLI not found"
}

test_only_plugins_unknown_id_hard_fails() {
    local stub_dir="$TMPDIR_ROOT/stub-bin"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/claude" <<'EOF'
#!/bin/sh
if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
  echo '[{"id":"real-one@marketplace"},{"id":"real-two@marketplace"}]'
  exit 0
fi
exit 0
EOF
    chmod +x "$stub_dir/claude"

    rc=0
    out=$(PATH="$stub_dir:$PATH" "$CW" --dry-run --only-plugins missing-a@m,real-one@marketplace,missing-b@m 2>&1) || rc=$?
    assert_eq "only-plugins with unknown ids exits non-zero" "1" "$rc"
    assert_contains "only-plugins error names first missing id" "$out" "missing-a@m"
    assert_contains "only-plugins error names second missing id" "$out" "missing-b@m"
    assert_not_contains "only-plugins error omits installed id" "$out" "not installed per 'claude plugin list --json': real-one"

    local home="$TMPDIR_ROOT/fixture-only-plugins"
    mkdir -p "$home/marketplaces/marketplace/plugins/real-one/.claude-plugin"
    printf '{"name":"real-one","description":"d"}\n' > "$home/marketplaces/marketplace/plugins/real-one/.claude-plugin/plugin.json"
    mkdir -p "$home/marketplaces/marketplace/.claude-plugin"
    cat > "$home/marketplaces/marketplace/.claude-plugin/marketplace.json" <<'EOF'
{"name": "marketplace", "plugins": [
  {"name": "real-one", "description": "d", "source": "./plugins/real-one"}
]}
EOF

    json=$(PATH="$stub_dir:$PATH" CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" --dry-run --only-plugins real-one@marketplace 2>&1 | sed -n '/^# generated settings JSON:$/,/^# claude command:$/p' | sed '1d;$d')
    assert_contains "only-plugins keeps listed installed id" "$json" '"real-one@marketplace": true'
    assert_contains "only-plugins disables other installed id" "$json" '"real-two@marketplace": false'

    cmd=$(PATH="$stub_dir:$PATH" CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" --dry-run --only-plugins real-one@marketplace 2>&1 | sed -n '/^# claude command:$/,$p' | sed '1d')
    assert_contains "only-plugins resolves the kept id to a --plugin-dir" "$cmd" "--plugin-dir $home/marketplaces/marketplace/plugins/real-one"
}

test_only_plugins_kept_id_unresolvable_exits_nonzero() {
    local stub_dir="$TMPDIR_ROOT/stub-bin-unresolvable"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/claude" <<'EOF'
#!/bin/sh
if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
  echo '[{"id":"real-one@marketplace"}]'
  exit 0
fi
exit 0
EOF
    chmod +x "$stub_dir/claude"

    rc=0
    out=$(PATH="$stub_dir:$PATH" CLAUDE_WITH_PLUGINS_HOME="$EMPTY_PLUGINS_HOME" "$CW" --dry-run --only-plugins real-one@marketplace 2>&1) || rc=$?
    assert_eq "only-plugins kept id with no on-disk marketplace exits non-zero" "1" "$rc"
    assert_contains "error names the unresolvable kept id" "$out" "real-one@marketplace"
}

test_settings_passthrough_merges_with_generated_keys() {
    base="$TMPDIR_ROOT/base_settings.json"
    printf '{"model": "sonnet"}\n' > "$base"

    json=$(settings_json_of --settings "$base" --no-plugin x@y)
    assert_contains "settings passthrough keeps base key" "$json" '"model": "sonnet"'
    assert_contains "settings passthrough keeps generated key" "$json" '"x@y": false'
}

test_settings_passthrough_json_string() {
    json=$(settings_json_of --settings '{"model": "opus"}')
    assert_contains "settings passthrough accepts inline JSON" "$json" '"model": "opus"'
}

test_double_dash_passes_remaining_args_verbatim() {
    cmd=$(command_of --no-plugin x@y -- --model sonnet --add-dir /tmp)
    assert_contains "-- passthrough keeps claude flags after settings" "$cmd" "--model sonnet --add-dir /tmp"
}

test_unknown_flag_fails() {
    assert_exit "unknown flag exits non-zero" 1 "$CW" --dry-run --totally-bogus-flag
}

test_missing_argument_fails() {
    assert_exit "--plugin without value exits non-zero" 1 "$CW" --dry-run --plugin
    assert_exit "--context without value exits non-zero" 1 "$CW" --dry-run --context
}

# ── Acceptance-criteria tests (verbatim from the launch brief) ──

test_acceptance_no_plugin_lsp() {
    out=$("$CW" --dry-run --no-plugin typescript-lsp@claude-plugins-official 2>&1)
    assert_contains "AC1: dry-run + no-plugin disables exactly that plugin" "$out" '"typescript-lsp@claude-plugins-official": false'
}

test_acceptance_no_context() {
    out=$("$CW" --dry-run --no-context 2>&1)
    assert_contains "AC2: dry-run + no-context excludes CLAUDE.md" "$out" '"claudeMdExcludes"'
}

# ── doctor ──

test_doctor_missing_registry_and_marketplaces_warns() {
    out=$(CLAUDE_WITH_PLUGINS_HOME="$EMPTY_PLUGINS_HOME" "$CW" doctor 2>&1)
    assert_contains "doctor warns on missing registry" "$out" "[WARN] plugin registry not found"
    assert_contains "doctor warns on missing marketplaces dir" "$out" "[WARN] marketplaces directory not found"
    assert_contains "doctor still reports claude OK" "$out" "[OK]   claude binary on PATH"
    rc=0
    CLAUDE_WITH_PLUGINS_HOME="$EMPTY_PLUGINS_HOME" "$CW" doctor >/dev/null 2>&1 || rc=$?
    assert_eq "doctor exits zero when nothing FAILs" "0" "$rc"
}

test_doctor_reports_good_and_stale_installlocations() {
    local home="$TMPDIR_ROOT/fixture-doctor"
    make_plugin_fixture "$home"

    out=$(CLAUDE_WITH_PLUGINS_HOME="$home" "$CW" doctor 2>&1)
    assert_contains "doctor OKs a valid installLocation" "$out" "[OK]   marketplace 'goodmarket': installLocation exists"
    assert_contains "doctor WARNs a stale installLocation" "$out" "[WARN] marketplace 'staleloc': installLocation does not exist"
    assert_contains "doctor notes when no on-disk content backs a stale entry" "$out" "no on-disk marketplace content found either"
}

test_doctor_fails_when_claude_missing_from_path() {
    local bin_dir="$TMPDIR_ROOT/no-claude-bin-doctor"
    mkdir -p "$bin_dir"
    for tool in bash python3; do
        ln -s "$(command -v "$tool")" "$bin_dir/$tool"
    done

    rc=0
    out=$(PATH="$bin_dir" CLAUDE_WITH_PLUGINS_HOME="$EMPTY_PLUGINS_HOME" "$CW" doctor 2>&1) || rc=$?
    assert_eq "doctor exits non-zero when claude is missing" "1" "$rc"
    assert_contains "doctor reports FAIL for missing claude" "$out" "[FAIL] claude binary not found"
}

# ============================================================
# Run
# ============================================================

echo "=== claude-with tests ==="
test_help_and_version
test_dry_run_no_flags_is_plain_claude
test_no_plugin_disables_exact_plugin
test_plugin_enables_exact_plugin
test_plugin_and_no_plugin_repeatable
test_plugin_resolves_inline_manifest_via_synthesis
test_plugin_unresolvable_marketplace_missing_exits_nonzero
test_plugin_unresolvable_name_exits_nonzero
test_plugin_remote_source_unresolvable_exits_nonzero
test_no_plugin_does_not_require_resolution
test_preflight_warns_stale_installlocation_on_every_invocation
test_preflight_non_object_registry_warns_and_continues
test_synth_dir_removed_when_later_plugin_fails
test_no_context_excludes_all_discovered_claude_md
test_no_context_excludes_subdirectory_claude_md
test_context_file_appends_system_prompt_and_excludes_claude_md
test_context_dir_concatenates_into_tmpfile
test_context_missing_path_fails
test_only_plugins_requires_claude_on_path
test_only_plugins_unknown_id_hard_fails
test_only_plugins_kept_id_unresolvable_exits_nonzero
test_settings_passthrough_merges_with_generated_keys
test_settings_passthrough_json_string
test_double_dash_passes_remaining_args_verbatim
test_unknown_flag_fails
test_missing_argument_fails
test_acceptance_no_plugin_lsp
test_acceptance_no_context
test_doctor_missing_registry_and_marketplaces_warns
test_doctor_reports_good_and_stale_installlocations
test_doctor_malformed_registry_json_fails
test_doctor_fails_when_claude_missing_from_path

echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
echo ""
for line in "${TESTS[@]}"; do
    echo "$line"
done

exit "$FAIL"
