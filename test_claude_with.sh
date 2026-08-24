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

cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

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
    json=$(settings_json_of --plugin skill-creator@claude-plugins-official)
    assert_contains "plugin sets id true" "$json" '"skill-creator@claude-plugins-official": true'
}

test_plugin_and_no_plugin_repeatable() {
    json=$(settings_json_of --plugin a@m --plugin b@m --no-plugin c@m --no-plugin d@m)
    assert_contains "repeatable --plugin a" "$json" '"a@m": true'
    assert_contains "repeatable --plugin b" "$json" '"b@m": true'
    assert_contains "repeatable --no-plugin c" "$json" '"c@m": false'
    assert_contains "repeatable --no-plugin d" "$json" '"d@m": false'
}

test_no_context_excludes_all_discovered_claude_md() {
    json=$(settings_json_of --no-context)
    assert_contains "no-context sets claudeMdExcludes" "$json" '"claudeMdExcludes"'
    assert_contains "no-context excludes cwd CLAUDE.md" "$json" "$(pwd)/CLAUDE.md"
    assert_contains "no-context excludes user CLAUDE.md" "$json" "$HOME/.claude/CLAUDE.md"
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
}

test_context_missing_path_fails() {
    assert_exit "missing --context path exits non-zero" 1 "$CW" --dry-run --context "$TMPDIR_ROOT/does-not-exist"
}

test_only_plugins_requires_claude_on_path() {
    local claude_path claude_dir stripped_path
    claude_path=$(command -v claude) || { TESTS+=("  SKIP  only-plugins missing-claude (no claude on PATH to strip)"); return; }
    claude_dir=$(dirname "$claude_path")
    stripped_path=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vF -- "$claude_dir" | tr '\n' ':')

    rc=0
    out=$(PATH="$stripped_path" "$CW" --dry-run --only-plugins foo@bar 2>&1) || rc=$?
    assert_eq "only-plugins without claude on PATH fails" "1" "$rc"
    assert_contains "only-plugins missing-claude error message" "$out" "claude CLI not found"
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

# ============================================================
# Run
# ============================================================

echo "=== claude-with tests ==="
test_help_and_version
test_dry_run_no_flags_is_plain_claude
test_no_plugin_disables_exact_plugin
test_plugin_enables_exact_plugin
test_plugin_and_no_plugin_repeatable
test_no_context_excludes_all_discovered_claude_md
test_context_file_appends_system_prompt_and_excludes_claude_md
test_context_dir_concatenates_into_tmpfile
test_context_missing_path_fails
test_only_plugins_requires_claude_on_path
test_settings_passthrough_merges_with_generated_keys
test_settings_passthrough_json_string
test_double_dash_passes_remaining_args_verbatim
test_unknown_flag_fails
test_missing_argument_fails
test_acceptance_no_plugin_lsp
test_acceptance_no_context

echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
echo ""
for line in "${TESTS[@]}"; do
    echo "$line"
done

exit "$FAIL"
