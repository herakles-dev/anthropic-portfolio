#!/bin/bash
# V11 Hook: sync-tasks (PostToolUse — TaskCreate|TaskUpdate|TaskList)
# Writes centralized task state to ~/.agent-metrics/task-state/{project}.json
#
# Replaces V8 sync-task-state (198 lines) by using lib/common.sh and flock.
# Project detection: metadata.project -> active-project file
#
# Exit codes:
#   0 - Always (PostToolUse hooks never block)

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Self-test for hook validation
if [ "$1" == "--test" ]; then
    echo "sync-tasks v1"
    exit 0
fi

# --- Parse input ---
v11_parse_input

# Only handle Task tools
case "$V11_TOOL_NAME" in
    TaskCreate|TaskUpdate|TaskList) ;;
    *) exit 0 ;;
esac

# --- Parse task details from output ---
TASK_ID=""
TASK_STATUS=""

case "$V11_TOOL_NAME" in
    TaskCreate)
        # Output: "Task #N created successfully: SUBJECT"
        TASK_ID=$(printf '%s' "$V11_TOOL_OUTPUT" | grep -oP 'Task #\K\d+')
        TASK_STATUS="pending"
        ;;
    TaskUpdate)
        # Output: "Updated task #N" or similar
        TASK_ID=$(printf '%s' "$V11_TOOL_OUTPUT" | grep -oP 'task #\K\d+')
        TASK_STATUS=$(printf '%s' "$V11_RAW_INPUT" | jq -r '.tool_input.status // ""' 2>/dev/null)
        ;;
esac

# --- Detect project ---
PROJECT=""

# Strategy 1: Explicit metadata.project in tool input
PROJECT=$(printf '%s' "$V11_RAW_INPUT" | jq -r '.tool_input.metadata.project // ""' 2>/dev/null)
[ "$PROJECT" = "null" ] && PROJECT=""

# Strategy 2: Active project file (set by guard-task-state or previous sync)
if [ -z "$PROJECT" ] && [ -f "$ACTIVE_PROJECT_FILE" ]; then
    PROJECT=$(cat "$ACTIVE_PROJECT_FILE" 2>/dev/null)
    [ "$PROJECT" = "null" ] && PROJECT=""
fi

# No project found -> nothing to sync
[ -z "$PROJECT" ] && exit 0

# Persist active project for downstream hooks
mkdir -p "$(dirname "$ACTIVE_PROJECT_FILE")"
printf '%s\n' "$PROJECT" > "$ACTIVE_PROJECT_FILE"

# --- Load or initialize task state ---
mkdir -p "$TASK_STATE_DIR"
STATE_FILE="$TASK_STATE_DIR/${PROJECT}.json"
NOW=$(date -Iseconds)

if [ -f "$STATE_FILE" ]; then
    STATE=$(cat "$STATE_FILE")
else
    STATE=$(jq -n --arg project "$PROJECT" --arg now "$NOW" '{
        project: $project,
        total: 0, completed: 0, pending: 0,
        in_progress: 0, blocked: 0,
        phase: "discovery",
        active_task: null, active_task_ids: [],
        recent_completed: [],
        last_updated: $now
    }')
fi

# --- Update state based on action ---
case "$V11_TOOL_NAME" in
    TaskCreate)
        # V11: Advisory schema validation on task metadata
        METADATA=$(printf '%s' "$V11_RAW_INPUT" | jq -c '.tool_input.metadata // empty' 2>/dev/null)
        if [ -n "$METADATA" ] && [ "$METADATA" != "null" ] && [ "$METADATA" != "" ]; then
            SCHEMA_WARN=$(mktemp /tmp/v11-schema-XXXXXX.txt)
            if ! v11_validate_json "$METADATA" "task-metadata.schema.json" 2>"$SCHEMA_WARN"; then
                echo "ADVISORY: Task metadata validation warning (task #$TASK_ID):" >&2
                cat "$SCHEMA_WARN" >&2
            fi
            rm -f "$SCHEMA_WARN"
        fi

        STATE=$(printf '%s' "$STATE" | jq --arg now "$NOW" '
            .total += 1 | .pending += 1 | .last_updated = $now
        ')
        ;;
    TaskUpdate)
        case "$TASK_STATUS" in
            in_progress)
                TASK_PHASE=$(printf '%s' "$V11_RAW_INPUT" | jq -r '.tool_input.metadata.phase // ""' 2>/dev/null)
                STATE=$(printf '%s' "$STATE" | jq \
                    --arg id "$TASK_ID" \
                    --arg phase "$TASK_PHASE" \
                    --arg now "$NOW" '
                    .pending = ([.pending - 1, 0] | max)
                    | .in_progress += 1
                    | .active_task_ids = ((.active_task_ids // []) + [$id] | unique)
                    | .phase = (if $phase == "" or $phase == "null" then .phase else $phase end)
                    | .last_updated = $now
                ')
                ;;
            completed)
                ACTIVE_SUBJECT=$(printf '%s' "$STATE" | jq -r '.active_task // "unknown"')
                STATE=$(printf '%s' "$STATE" | jq \
                    --arg id "$TASK_ID" \
                    --arg subject "$ACTIVE_SUBJECT" \
                    --arg now "$NOW" '
                    .in_progress = ([.in_progress - 1, 0] | max)
                    | .completed += 1
                    | .recent_completed = ([$subject] + .recent_completed)[:10]
                    | .active_task = null
                    | .active_task_ids = ((.active_task_ids // []) | map(select(. != $id)))
                    | .last_updated = $now
                ')

                # V11: Persist artifacts from completed task metadata
                ARTIFACTS=$(printf '%s' "$V11_RAW_INPUT" | jq -r '.tool_input.metadata.artifacts // empty' 2>/dev/null)
                if [ -n "$ARTIFACTS" ] && [ "$ARTIFACTS" != "null" ]; then
                    # Store artifacts indexed by task ID
                    STATE=$(printf '%s' "$STATE" | jq \
                        --arg id "$TASK_ID" \
                        --argjson arts "$ARTIFACTS" '
                        .task_artifacts = ((.task_artifacts // {}) + {($id): $arts})
                    ')

                    # Handle external storage for large artifact_refs
                    if [ -n "$PROJECT" ]; then
                        ARTIFACT_DIR="$SESSIONS_ROOT/$PROJECT/artifacts/$TASK_ID"
                        mkdir -p "$ARTIFACT_DIR" 2>/dev/null
                    fi
                fi
                ;;
            blocked)
                STATE=$(printf '%s' "$STATE" | jq \
                    --arg id "$TASK_ID" \
                    --arg now "$NOW" '
                    .in_progress = ([.in_progress - 1, 0] | max)
                    | .blocked += 1
                    | .active_task = null
                    | .active_task_ids = ((.active_task_ids // []) | map(select(. != $id)))
                    | .last_updated = $now
                ')
                ;;
        esac
        ;;
    TaskList)
        STATE=$(printf '%s' "$STATE" | jq --arg now "$NOW" '.last_updated = $now')
        ;;
esac

# --- Atomic write with flock (prevents teammate race conditions) ---
(
    flock -w 5 200 || exit 0
    printf '%s' "$STATE" | jq '.' > "$STATE_FILE"
) 200>"$STATE_FILE.lock"

# Mirror to sessions dir if it exists — flock prevents torn reads during cp
SESSION_DIR="$SESSIONS_ROOT/$PROJECT"
if [ -d "$SESSION_DIR" ]; then
    (
        flock -w 5 201 || exit 0
        cp "$STATE_FILE" "$SESSION_DIR/.task-state.json" 2>/dev/null
    ) 201>"$SESSION_DIR/.task-state.json.lock"
fi

# V11: Formation heartbeat pulse on TaskUpdate during active formations
if [ "$V11_TOOL_NAME" = "TaskUpdate" ] && [ -n "$PROJECT" ]; then
    FORMATION_REG="$SESSIONS_ROOT/$PROJECT/.formation-registry.json"
    if [ -f "$FORMATION_REG" ]; then
        TOTAL=$(printf '%s' "$STATE" | jq -r '.total // 0')
        COMPLETED=$(printf '%s' "$STATE" | jq -r '.completed // 0')
        IN_PROG=$(printf '%s' "$STATE" | jq -r '.in_progress // 0')
        PENDING=$(printf '%s' "$STATE" | jq -r '.pending // 0')
        BLOCKED=$(printf '%s' "$STATE" | jq -r '.blocked // 0')
        PCT=0
        [ "$TOTAL" -gt 0 ] && PCT=$(( COMPLETED * 100 / TOTAL ))
        echo "Formation pulse [$PROJECT]: ${COMPLETED}/${TOTAL} tasks (${PCT}%) | active=$IN_PROG pending=$PENDING blocked=$BLOCKED"
    fi
fi

# V11.4: Sync plan file on task status transitions (background, no latency impact)
if [ "$TASK_STATUS" = "completed" ] || [ "$TASK_STATUS" = "in_progress" ]; then
    PLAN_SYNC_SCRIPT="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/scripts/plan-sync"
    if [ -x "$PLAN_SYNC_SCRIPT" ] && [ -n "$PROJECT" ]; then
        "$PLAN_SYNC_SCRIPT" "$PROJECT" &>/dev/null &
    fi
fi

# V11: Trigger delta memory index on task completion with artifacts
if [ "$TASK_STATUS" = "completed" ] && [ -n "$ARTIFACTS" ] && [ "$ARTIFACTS" != "null" ]; then
    INDEX_SCRIPT="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/scripts/index-project-memory"
    if [ -x "$INDEX_SCRIPT" ] && [ -n "$PROJECT" ]; then
        # Background delta index — no performance impact on hook
        "$INDEX_SCRIPT" "$PROJECT" --delta "$STATE_FILE" &>/dev/null &
    fi
fi

exit 0
