#!/bin/bash
# V11 Enforce Test Coverage - PreToolUse hook
# Blocks deployment commands if test coverage is below threshold
#
# Exit codes:
#   0 - Allow operation (coverage meets threshold, or not a deploy)
#   2 - Block operation (coverage below threshold)
#   1 - Error (allow operation, log warning)

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V11_HOME="${SCRIPT_DIR%/hooks}"
SESSIONS_ROOT="${SESSIONS_ROOT:-/home/hercules/sessions}"

# Default coverage threshold (can be overridden per project)
DEFAULT_THRESHOLD=80

# Test mode
if [ "$1" == "--test" ]; then
    echo "enforce-test-coverage hook test"
    echo "V11_HOME: $V11_HOME"
    echo "Default threshold: $DEFAULT_THRESHOLD%"
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat)

# Parse tool info
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Skip non-Bash tools
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Skip empty commands
if [ -z "$COMMAND" ]; then
    exit 0
fi

# Check if this is a deployment command
IS_DEPLOYMENT=false
if echo "$COMMAND" | grep -qiE "(docker-compose up|docker compose up|kubectl apply|./deploy\.sh|/deploy-service|deploy.sh)"; then
    IS_DEPLOYMENT=true
fi

# Skip non-deployment commands
if [ "$IS_DEPLOYMENT" = false ]; then
    exit 0
fi

# Detect project directory
CWD=$(echo "$INPUT" | jq -r '.working_directory // ""' 2>/dev/null)
PROJECT_DIR="$CWD"

# If in V11 sessions, get project
PROJECT=""
if [[ "$CWD" =~ $SESSIONS_ROOT/ ]]; then
    PROJECT=$(echo "$CWD" | sed -n "s|$SESSIONS_ROOT/\([^/]*\).*|\1|p")
    PROJECT_DIR="$SESSIONS_ROOT/$PROJECT"
fi

# Check for project-specific threshold (from environment variable)
THRESHOLD=${TEST_COVERAGE_THRESHOLD:-$DEFAULT_THRESHOLD}

# --- Cache framework detection for performance ---
CACHE_FILE="$METRICS_DIR/test-framework-cache.json"
CACHED_FRAMEWORK=""

# Try to read from cache
if [ -f "$CACHE_FILE" ]; then
    CACHE_ENTRY=$(jq -r --arg dir "$PROJECT_DIR" '.caches[$dir] // empty' "$CACHE_FILE" 2>/dev/null)
    if [ -n "$CACHE_ENTRY" ]; then
        CACHED_CONFIG_FILE=$(echo "$CACHE_ENTRY" | jq -r '.config_file')
        CACHED_MTIME=$(echo "$CACHE_ENTRY" | jq -r '.config_mtime')
        ACTUAL_MTIME=$(stat -c %Y "$CACHED_CONFIG_FILE" 2>/dev/null || echo "0")

        # Validate cache: config file mtime must match
        if [ "$CACHED_MTIME" == "$ACTUAL_MTIME" ]; then
            CACHED_FRAMEWORK=$(echo "$CACHE_ENTRY" | jq -r '.framework')
        fi
    fi
fi

# Helper function to write framework to cache
write_framework_cache() {
    local proj="$1" framework="$2" config="$3"
    [ ! -d "$METRICS_DIR" ] && mkdir -p "$METRICS_DIR"

    local cache_json=$(cat "$CACHE_FILE" 2>/dev/null || echo '{"version":"1.0","caches":{}}')
    local mtime=$(stat -c %Y "$config" 2>/dev/null || echo "0")

    cache_json=$(echo "$cache_json" | jq --arg proj "$proj" --arg fw "$framework" --arg cfg "$config" --argjson mtime "$mtime" \
        '.caches[$proj] = {
            "framework": $fw,
            "config_file": $cfg,
            "cached_at": "'$(date -Iseconds)'",
            "config_mtime": $mtime,
            "validity_check": "config_mtime_match"
        }')

    (
        flock -w 5 200 || exit 0
        echo "$cache_json" > "$CACHE_FILE.tmp"
        mv "$CACHE_FILE.tmp" "$CACHE_FILE" 2>/dev/null
    ) 200>"$CACHE_FILE.lock"
}

# Detect test framework and run coverage check
COVERAGE=""
TEST_FRAMEWORK="$CACHED_FRAMEWORK"

# Python: pytest with coverage
if [ -z "$TEST_FRAMEWORK" ]; then
    if [ -f "$PROJECT_DIR/pytest.ini" ] || [ -f "$PROJECT_DIR/setup.py" ] || [ -f "$PROJECT_DIR/pyproject.toml" ]; then
        TEST_FRAMEWORK="pytest"
        CONFIG_FILE="$PROJECT_DIR/pyproject.toml"
        [ -f "$PROJECT_DIR/pytest.ini" ] && CONFIG_FILE="$PROJECT_DIR/pytest.ini"
        write_framework_cache "$PROJECT_DIR" "pytest" "$CONFIG_FILE"

        if command -v pytest &> /dev/null; then
            # Run pytest with coverage in project directory
            cd "$PROJECT_DIR" 2>/dev/null
            COVERAGE_OUTPUT=$(pytest --cov --cov-report=term-missing --tb=no -q 2>&1 || true)
            # Extract coverage percentage (format: "TOTAL ... XX%")
            COVERAGE=$(echo "$COVERAGE_OUTPUT" | grep "TOTAL" | grep -oP '\d+%' | tail -1 | tr -d '%')
        fi
    fi
fi

# JavaScript/TypeScript: jest
if [ -z "$TEST_FRAMEWORK" ] && [ -z "$COVERAGE" ] && ([ -f "$PROJECT_DIR/jest.config.js" ] || [ -f "$PROJECT_DIR/jest.config.ts" ]); then
    TEST_FRAMEWORK="jest"
    CONFIG_FILE="$PROJECT_DIR/jest.config.js"
    [ -f "$PROJECT_DIR/jest.config.ts" ] && CONFIG_FILE="$PROJECT_DIR/jest.config.ts"
    write_framework_cache "$PROJECT_DIR" "jest" "$CONFIG_FILE"

    if command -v jest &> /dev/null; then
        cd "$PROJECT_DIR" 2>/dev/null
        COVERAGE_OUTPUT=$(jest --coverage --silent 2>&1 || true)
        # Extract coverage percentage from jest output
        COVERAGE=$(echo "$COVERAGE_OUTPUT" | grep "All files" | grep -oP '\d+\.\d+' | head -1 | cut -d. -f1)
    fi
fi

# Go: go test with coverage
if [ -z "$TEST_FRAMEWORK" ] && [ -z "$COVERAGE" ] && [ -f "$PROJECT_DIR/go.mod" ]; then
    TEST_FRAMEWORK="go test"
    write_framework_cache "$PROJECT_DIR" "go test" "$PROJECT_DIR/go.mod"

    if command -v go &> /dev/null; then
        cd "$PROJECT_DIR" 2>/dev/null
        COVERAGE_OUTPUT=$(go test -cover ./... 2>&1 || true)
        # Extract coverage percentage
        COVERAGE=$(echo "$COVERAGE_OUTPUT" | grep "coverage:" | grep -oP '\d+\.\d+' | head -1 | cut -d. -f1)
    fi
fi

# Rust: cargo test with tarpaulin (if available)
if [ -z "$TEST_FRAMEWORK" ] && [ -z "$COVERAGE" ] && [ -f "$PROJECT_DIR/Cargo.toml" ]; then
    TEST_FRAMEWORK="cargo test"
    write_framework_cache "$PROJECT_DIR" "cargo test" "$PROJECT_DIR/Cargo.toml"

    if command -v cargo &> /dev/null; then
        cd "$PROJECT_DIR" 2>/dev/null
        if command -v cargo-tarpaulin &> /dev/null; then
            COVERAGE_OUTPUT=$(cargo tarpaulin --quiet 2>&1 || true)
            COVERAGE=$(echo "$COVERAGE_OUTPUT" | grep -oP '\d+\.\d+%' | tail -1 | tr -d '%' | cut -d. -f1)
        else
            # Just run tests without coverage
            cargo test --quiet 2>&1 || true
        fi
    fi
fi

# Bun: bun test
if [ -z "$TEST_FRAMEWORK" ] && [ -z "$COVERAGE" ] && [ -f "$PROJECT_DIR/bunfig.toml" ]; then
    TEST_FRAMEWORK="bun test"
    write_framework_cache "$PROJECT_DIR" "bun test" "$PROJECT_DIR/bunfig.toml"

    if command -v bun &> /dev/null; then
        cd "$PROJECT_DIR" 2>/dev/null
        COVERAGE_OUTPUT=$(bun test --coverage 2>&1 || true)
        COVERAGE=$(echo "$COVERAGE_OUTPUT" | grep -oP '\d+\.\d+%' | tail -1 | tr -d '%' | cut -d. -f1)
    fi
fi

# If no test framework detected or coverage couldn't be determined
if [ -z "$TEST_FRAMEWORK" ]; then
    # No tests configured - issue warning but allow
    echo "⚠️  Warning: No test framework detected, skipping coverage check"
    exit 0
fi

if [ -z "$COVERAGE" ]; then
    # Tests exist but coverage couldn't be determined - issue warning
    echo "⚠️  Warning: Could not determine test coverage, allowing deployment"
    echo "   Framework: $TEST_FRAMEWORK"
    echo "   Run tests manually: cd $PROJECT_DIR && $TEST_FRAMEWORK --coverage"
    exit 0
fi

# Check if coverage meets threshold
if [ "$COVERAGE" -lt "$THRESHOLD" ]; then
    cat << EOF
❌ TEST COVERAGE BELOW THRESHOLD

Current Coverage: $COVERAGE%
Required Threshold: $THRESHOLD%
Gap: $((THRESHOLD - COVERAGE))%
Framework: $TEST_FRAMEWORK

Deployment blocked to prevent deploying untested code.

Options:
1. Write more tests to reach $THRESHOLD% coverage
2. Lower threshold in .claude/settings.json:
   {
     "test_coverage_threshold": $COVERAGE
   }
3. Skip coverage check (NOT RECOMMENDED):
   Add --skip-coverage flag to deploy command
   OR add to state.md:
   ---
   COVERAGE CHECK SKIPPED
   Reason: [explain why]
   Date: $(date -Iseconds)
   ---

Run tests: cd $PROJECT_DIR && $TEST_FRAMEWORK --coverage
EOF
    exit 2
fi

# Coverage meets threshold
echo "✓ Test coverage: $COVERAGE% (threshold: $THRESHOLD%)"
exit 0
