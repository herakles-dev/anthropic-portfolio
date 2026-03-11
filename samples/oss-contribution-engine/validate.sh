#!/bin/bash
# validate.sh - Pre-flight validation before committing to an issue
# Checks: competing PRs, claimed status, staleness, CONTRIBUTING.md, labels
# Usage: ./scripts/validate.sh OWNER/REPO NUMBER
#
# Exit codes:
#   0 = CLEAR — safe to claim and work on
#   1 = BLOCKED — competing PR or claimed, do not pursue
#   2 = CAUTION — proceed with care (stale claim, no contributing guide, etc.)

set -euo pipefail

REPO="${1:?Usage: $0 OWNER/REPO ISSUE_NUMBER}"
NUMBER="${2:?Usage: $0 OWNER/REPO ISSUE_NUMBER}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

WARNINGS=0
BLOCKERS=0

echo -e "${CYAN}=== Issue Validation: ${REPO}#${NUMBER} ===${NC}"
echo ""

# -----------------------------------------------
# 1. Fetch issue metadata
# -----------------------------------------------
echo -e "${CYAN}[1/8] Fetching issue...${NC}"
ISSUE_JSON=$(gh issue view "$NUMBER" -R "$REPO" \
    --json title,state,labels,comments,createdAt,author,assignees,body \
    2>/dev/null) || { echo -e "${RED}FAIL: Could not fetch issue. Check repo/number.${NC}"; exit 1; }

TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
STATE=$(echo "$ISSUE_JSON" | jq -r '.state')
LABEL_LIST=$(echo "$ISSUE_JSON" | jq -r '[.labels[].name] | join(", ")')
COMMENT_COUNT=$(echo "$ISSUE_JSON" | jq '.comments | length')
ASSIGNEE_COUNT=$(echo "$ISSUE_JSON" | jq '.assignees | length')
CREATED=$(echo "$ISSUE_JSON" | jq -r '.createdAt')

echo "  Title: $TITLE"
echo "  State: $STATE | Labels: ${LABEL_LIST:-none} | Comments: $COMMENT_COUNT"

if [[ "$STATE" != "OPEN" ]]; then
    echo -e "${RED}BLOCKER: Issue is $STATE, not OPEN.${NC}"
    BLOCKERS=$((BLOCKERS + 1))
fi

# -----------------------------------------------
# 2. Check if issue is assigned
# -----------------------------------------------
echo ""
echo -e "${CYAN}[2/8] Checking assignments...${NC}"
if [[ "$ASSIGNEE_COUNT" -gt 0 ]]; then
    ASSIGNEES=$(echo "$ISSUE_JSON" | jq -r '[.assignees[].login] | join(", ")')
    echo -e "${RED}BLOCKER: Issue is assigned to: $ASSIGNEES${NC}"
    BLOCKERS=$((BLOCKERS + 1))
else
    echo -e "${GREEN}  No assignees — open for claiming.${NC}"
fi

# -----------------------------------------------
# 3. Check for competing PRs
# -----------------------------------------------
echo ""
echo -e "${CYAN}[3/8] Checking for competing PRs...${NC}"
COMPETING_PRS=$(gh pr list -R "$REPO" --search "$NUMBER" --state=open \
    --json number,title,author,createdAt \
    --jq '.[] | select(.title | test("#?'"$NUMBER"'"; "i")) | "#\(.number) by \(.author.login) — \(.title)"' \
    2>/dev/null || true)

# Also search by issue reference in PR body
LINKED_PRS=$(gh pr list -R "$REPO" --search "fixes #$NUMBER OR closes #$NUMBER OR resolves #$NUMBER" --state=open \
    --json number,title,author \
    --jq '.[] | "#\(.number) by \(.author.login) — \(.title)"' \
    2>/dev/null || true)

ALL_PRS=$(echo -e "${COMPETING_PRS}\n${LINKED_PRS}" | sort -u | grep -v '^$' || true)

if [[ -n "$ALL_PRS" ]]; then
    echo -e "${RED}BLOCKER: Competing PRs found:${NC}"
    echo "$ALL_PRS" | while read -r line; do echo "    $line"; done
    BLOCKERS=$((BLOCKERS + 1))
else
    echo -e "${GREEN}  No competing PRs found.${NC}"
fi

# -----------------------------------------------
# 4. Check comments for claims ("I'll take this", "working on this", etc.)
# -----------------------------------------------
echo ""
echo -e "${CYAN}[4/8] Scanning comments for claims...${NC}"
CLAIM_PATTERNS="I'll take this|I will take this|working on this|I'll fix this|will have a PR|taking this|I'm on it|I can take this|picking this up|I'll submit a PR|claimed|I'll work on"

CLAIM_COMMENTS=$(echo "$ISSUE_JSON" | jq -r \
    --arg patterns "$CLAIM_PATTERNS" \
    '.comments[] | select(.body | test($patterns; "i")) | "\(.author.login) (\(.createdAt[0:10])): \(.body[0:120])"' \
    2>/dev/null || true)

if [[ -n "$CLAIM_COMMENTS" ]]; then
    # Check if claim is stale (>14 days old with no follow-up PR)
    LATEST_CLAIM_DATE=$(echo "$ISSUE_JSON" | jq -r \
        --arg patterns "$CLAIM_PATTERNS" \
        '[.comments[] | select(.body | test($patterns; "i")) | .createdAt] | max' \
        2>/dev/null || echo "")

    if [[ -n "$LATEST_CLAIM_DATE" ]]; then
        CLAIM_EPOCH=$(date -d "$LATEST_CLAIM_DATE" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        CLAIM_AGE_DAYS=$(( (NOW_EPOCH - CLAIM_EPOCH) / 86400 ))

        if [[ "$CLAIM_AGE_DAYS" -gt 14 ]] && [[ -z "$ALL_PRS" ]]; then
            echo -e "${YELLOW}CAUTION: Stale claim found (${CLAIM_AGE_DAYS} days old, no PR submitted):${NC}"
            echo "$CLAIM_COMMENTS" | head -3 | while read -r line; do echo "    $line"; done
            echo -e "${YELLOW}  Consider commenting: 'Is this still being worked on? Happy to help or take over.'${NC}"
            WARNINGS=$((WARNINGS + 1))
        else
            echo -e "${RED}BLOCKER: Active claim found:${NC}"
            echo "$CLAIM_COMMENTS" | head -3 | while read -r line; do echo "    $line"; done
            BLOCKERS=$((BLOCKERS + 1))
        fi
    fi
else
    echo -e "${GREEN}  No claims found in comments.${NC}"
fi

# -----------------------------------------------
# 5. Check labels for "not ready" signals
# -----------------------------------------------
echo ""
echo -e "${CYAN}[5/8] Checking labels...${NC}"
BLOCK_LABELS="needs confirmation|needs maintainer|wontfix|duplicate|stale|invalid|not a bug"
HAS_BLOCK_LABEL=$(echo "$ISSUE_JSON" | jq -r \
    --arg patterns "$BLOCK_LABELS" \
    '[.labels[].name | select(test($patterns; "i"))] | length' \
    2>/dev/null || echo 0)

if [[ "$HAS_BLOCK_LABEL" -gt 0 ]]; then
    BLOCKING_LABELS=$(echo "$ISSUE_JSON" | jq -r \
        --arg patterns "$BLOCK_LABELS" \
        '[.labels[].name | select(test($patterns; "i"))] | join(", ")' \
        2>/dev/null)
    echo -e "${YELLOW}CAUTION: Issue has blocking labels: $BLOCKING_LABELS${NC}"
    echo "  These labels indicate maintainers haven't confirmed the issue is ready."
    WARNINGS=$((WARNINGS + 1))
else
    echo -e "${GREEN}  No blocking labels.${NC}"
fi

INVITE_LABELS="good first issue|help wanted|ready for work|contributions welcome|easy"
HAS_INVITE=$(echo "$ISSUE_JSON" | jq -r \
    --arg patterns "$INVITE_LABELS" \
    '[.labels[].name | select(test($patterns; "i"))] | length' \
    2>/dev/null || echo 0)

if [[ "$HAS_INVITE" -gt 0 ]]; then
    echo -e "${GREEN}  Has invitation labels — maintainers want contributions here.${NC}"
fi

# -----------------------------------------------
# 6. Check CONTRIBUTING.md exists
# -----------------------------------------------
echo ""
echo -e "${CYAN}[6/8] Checking CONTRIBUTING.md...${NC}"
HAS_CONTRIBUTING=$(gh api "repos/$REPO/contents/CONTRIBUTING.md" --jq '.name' 2>/dev/null || true)

if [[ "$HAS_CONTRIBUTING" == "CONTRIBUTING.md" ]]; then
    echo -e "${GREEN}  CONTRIBUTING.md exists. READ IT before submitting.${NC}"

    # Check for CLA requirements
    CONTRIBUTING_BODY=$(gh api "repos/$REPO/contents/CONTRIBUTING.md" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if echo "$CONTRIBUTING_BODY" | grep -qi "CLA\|contributor license\|sign.*agreement"; then
        echo -e "${YELLOW}  NOTE: This project may require a CLA (Contributor License Agreement).${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
    if echo "$CONTRIBUTING_BODY" | grep -qi "comment.*issue\|claim.*issue\|assign.*you"; then
        echo -e "${YELLOW}  NOTE: Contributing guide says to comment/claim issues before working.${NC}"
    fi
else
    echo -e "${YELLOW}CAUTION: No CONTRIBUTING.md found. Check README for contribution guidelines.${NC}"
    WARNINGS=$((WARNINGS + 1))
fi

# -----------------------------------------------
# 7. Issue age and activity check
# -----------------------------------------------
echo ""
echo -e "${CYAN}[7/8] Checking freshness...${NC}"
CREATED_EPOCH=$(date -d "$CREATED" +%s 2>/dev/null || echo 0)
NOW_EPOCH=$(date +%s)
AGE_DAYS=$(( (NOW_EPOCH - CREATED_EPOCH) / 86400 ))

if [[ "$AGE_DAYS" -gt 365 ]]; then
    echo -e "${YELLOW}CAUTION: Issue is ${AGE_DAYS} days old. May be stale or deprioritized.${NC}"
    WARNINGS=$((WARNINGS + 1))
elif [[ "$AGE_DAYS" -gt 90 ]]; then
    echo -e "${YELLOW}  Issue is ${AGE_DAYS} days old. Check for recent activity.${NC}"
else
    echo -e "${GREEN}  Issue is ${AGE_DAYS} days old — fresh.${NC}"
fi

# -----------------------------------------------
# 8. Check comprehension & compliance data (advisory)
# -----------------------------------------------
echo ""
echo -e "${CYAN}[8/8] Checking comprehension & compliance data...${NC}"
SLUG="${REPO//\//-}"
COMP_DIR="$PROJECT_DIR/data/comprehension/$SLUG"

if [[ -d "$COMP_DIR" ]] && [[ -f "$COMP_DIR/scan-summary.md" ]]; then
    echo -e "${GREEN}  Comprehension data exists: $COMP_DIR/${NC}"
    if [[ -f "$COMP_DIR/compliance.md" ]]; then
        echo -e "${GREEN}  Compliance matrix exists.${NC}"
    else
        echo -e "${YELLOW}  NOTE: No compliance matrix. Run: ./scripts/compliance.sh $REPO${NC}"
    fi
else
    echo -e "${YELLOW}  NOTE: No comprehension data. Run: ./scripts/comprehend.sh $REPO --tier 1${NC}"
fi

# -----------------------------------------------
# VERDICT
# -----------------------------------------------
echo ""
echo "==========================================="

if [[ "$BLOCKERS" -gt 0 ]]; then
    echo -e "${RED}VERDICT: BLOCKED ($BLOCKERS blocker(s), $WARNINGS warning(s))${NC}"
    echo ""
    echo "Do NOT pursue this issue. Reasons above."
    echo "Actions:"
    echo "  - Find a different issue"
    echo "  - If competing PR is stale (30+ days), comment offering to help"
    exit 1
elif [[ "$WARNINGS" -gt 0 ]]; then
    echo -e "${YELLOW}VERDICT: CAUTION ($WARNINGS warning(s))${NC}"
    echo ""
    echo "Proceed carefully. Address warnings before investing time:"
    echo "  - Stale claims: comment asking if still active"
    echo "  - Blocking labels: wait for maintainer confirmation"
    echo "  - Missing CONTRIBUTING.md: check README instead"
    echo "  - CLA: sign it before submitting PR"
    exit 2
else
    echo -e "${GREEN}VERDICT: CLEAR — safe to claim and work on.${NC}"
    echo ""
    echo "Recommended next steps:"
    echo "  1. Comment on the issue to claim it"
    echo "  2. Read CONTRIBUTING.md (if exists)"
    echo "  3. Fork, branch, implement, test, PR"
    exit 0
fi
