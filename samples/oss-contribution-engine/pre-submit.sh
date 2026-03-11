#!/bin/bash
# pre-submit.sh - 10-check pre-submission gate
# Runs AFTER implementation, BEFORE gh pr create.
# Validates commits, security, quality, and methodology compliance.
#
# Usage: ./scripts/pre-submit.sh OWNER/REPO NUMBER [--fork-dir DIR] [--force]
#
# Exit codes:
#   0 = CLEAR — safe to submit PR
#   1 = BLOCKED — fix blockers before submitting
#   2 = CAUTION — warnings present, review before submitting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="${1:?Usage: $0 OWNER/REPO ISSUE_NUMBER [--fork-dir DIR] [--force]}"
NUMBER="${2:?Usage: $0 OWNER/REPO ISSUE_NUMBER [--fork-dir DIR] [--force]}"

shift 2

FORK_DIR=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fork-dir) FORK_DIR="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
    esac
done

OWNER="${REPO%%/*}"
REPONAME="${REPO##*/}"
SLUG="${OWNER}-${REPONAME}-${NUMBER}"
COMP_SLUG="${OWNER}-${REPONAME}"
ISSUE_DIR="$PROJECT_DIR/data/issues/$SLUG"
COMP_DIR="$PROJECT_DIR/data/comprehension/$COMP_SLUG"

# Detect fork directory
if [[ -z "$FORK_DIR" ]]; then
    if [[ -d "$PROJECT_DIR/data/forks/$REPONAME/.git" ]]; then
        FORK_DIR="$PROJECT_DIR/data/forks/$REPONAME"
    else
        FORK_DIR="$(pwd)"
    fi
fi

if [[ ! -d "$FORK_DIR/.git" ]]; then
    echo -e "${RED}ERROR: No git repository at $FORK_DIR${NC}"
    echo "  Use --fork-dir to specify the fork location."
    exit 1
fi

BLOCKERS=0
WARNINGS=0

echo -e "${CYAN}=== Pre-Submission Gate: ${REPO}#${NUMBER} ===${NC}"
echo "  Fork: $FORK_DIR"
echo ""

# Load compliance matrix if it exists
AI_DISCLOSURE="allowed"
DCO_REQUIRED="false"
TRAILERS_REQUIRED=""
FORBIDDEN_PATTERNS=""

if [[ -f "$COMP_DIR/compliance.md" ]]; then
    AI_DISCLOSURE=$(grep -oP 'policy: \K\S+' "$COMP_DIR/compliance.md" 2>/dev/null || echo "allowed")
    DCO_REQUIRED=$(grep -oP 'dco_required: \K\S+' "$COMP_DIR/compliance.md" 2>/dev/null || echo "false")
    TRAILERS_REQUIRED=$(grep -oP 'trailers_required: \K.*' "$COMP_DIR/compliance.md" 2>/dev/null || echo "")
    FORBIDDEN_PATTERNS=$(grep -oP 'forbidden_in_commits: \K.*' "$COMP_DIR/compliance.md" 2>/dev/null || echo "")
fi

# Get the diff against upstream
DIFF=$(cd "$FORK_DIR" && git diff HEAD~1..HEAD 2>/dev/null || git diff --cached 2>/dev/null || echo "")
LOG=$(cd "$FORK_DIR" && git log --oneline -5 2>/dev/null || echo "")

# -----------------------------------------------
# COMMITS CATEGORY
# -----------------------------------------------

# Check 1: Forbidden patterns in commits
echo -e "${CYAN}[1/10] Checking forbidden patterns in commits...${NC}"
if [[ -n "$FORBIDDEN_PATTERNS" ]]; then
    FOUND_FORBIDDEN=false
    # Split comma-separated patterns
    IFS=',' read -ra PATTERNS <<< "$FORBIDDEN_PATTERNS"
    for pattern in "${PATTERNS[@]}"; do
        pattern=$(echo "$pattern" | xargs) # trim whitespace
        if [[ -z "$pattern" ]]; then continue; fi
        # Use word-boundary match for short patterns to avoid false positives
        GREP_FLAG="-qi"
        if [[ ${#pattern} -le 3 ]]; then
            GREP_FLAG="-qiw"
        fi
        if cd "$FORK_DIR" && git log -1 --format="%B" 2>/dev/null | grep $GREP_FLAG "$pattern"; then
            echo -e "${RED}  BLOCKER: Forbidden pattern '$pattern' found in commit messages${NC}"
            FOUND_FORBIDDEN=true
        fi
    done
    if [[ "$FOUND_FORBIDDEN" == "true" ]]; then
        BLOCKERS=$((BLOCKERS + 1))
    else
        echo -e "${GREEN}  No forbidden patterns found.${NC}"
    fi
else
    echo -e "${GREEN}  No forbidden patterns configured.${NC}"
fi

# Check 2: Required trailers present
echo ""
echo -e "${CYAN}[2/10] Checking required trailers...${NC}"
if [[ -n "$TRAILERS_REQUIRED" ]] && [[ "$TRAILERS_REQUIRED" != "none" ]]; then
    MISSING_TRAILERS=false
    IFS=',' read -ra TRAILER_LIST <<< "$TRAILERS_REQUIRED"
    for trailer in "${TRAILER_LIST[@]}"; do
        trailer=$(echo "$trailer" | xargs) # trim whitespace
        if [[ -z "$trailer" ]]; then continue; fi
        # Extract just the trailer name (before colon if present)
        trailer_name="${trailer%%:*}"
        if ! cd "$FORK_DIR" || ! git log -1 --format="%B" 2>/dev/null | grep -qi "$trailer_name"; then
            echo -e "${RED}  BLOCKER: Required trailer '$trailer_name' missing from latest commit${NC}"
            MISSING_TRAILERS=true
        fi
    done
    if [[ "$MISSING_TRAILERS" == "true" ]]; then
        BLOCKERS=$((BLOCKERS + 1))
    else
        echo -e "${GREEN}  All required trailers present.${NC}"
    fi
else
    echo -e "${GREEN}  No specific trailers required.${NC}"
fi

# Check 3: Sign-off present when required (DCO)
echo ""
echo -e "${CYAN}[3/10] Checking DCO sign-off...${NC}"
if [[ "$DCO_REQUIRED" == "true" ]]; then
    if cd "$FORK_DIR" && git log -1 --format="%B" 2>/dev/null | grep -qi "Signed-off-by:"; then
        echo -e "${GREEN}  DCO sign-off present.${NC}"
    else
        echo -e "${RED}  BLOCKER: DCO sign-off required but missing. Use: git commit --signoff${NC}"
        BLOCKERS=$((BLOCKERS + 1))
    fi
else
    echo -e "${GREEN}  DCO not required.${NC}"
fi

# -----------------------------------------------
# SECURITY CATEGORY
# -----------------------------------------------

# Check 4: Secrets patterns in diff
echo ""
echo -e "${CYAN}[4/10] Scanning diff for secrets...${NC}"
SECRETS_FOUND=false

# Common secret patterns
SECRET_PATTERNS=(
    'AKIA[0-9A-Z]{16}'          # AWS Access Key
    'sk-[a-zA-Z0-9]{20,}'       # OpenAI/Stripe keys
    'ghp_[a-zA-Z0-9]{36}'       # GitHub PAT
    'glpat-[a-zA-Z0-9\-]{20,}'  # GitLab PAT
    'xox[bpors]-[a-zA-Z0-9\-]+'  # Slack token
    'PRIVATE KEY-----'           # Private key
    'password\s*=\s*["\x27][^"\x27]{8,}'  # Hardcoded passwords
    'api[_-]?key\s*=\s*["\x27][^"\x27]{8,}'  # API keys
)

for pattern in "${SECRET_PATTERNS[@]}"; do
    if echo "$DIFF" | grep -qEi "$pattern" 2>/dev/null; then
        echo -e "${RED}  BLOCKER: Potential secret detected matching pattern: ${pattern:0:30}...${NC}"
        SECRETS_FOUND=true
    fi
done

if [[ "$SECRETS_FOUND" == "true" ]]; then
    BLOCKERS=$((BLOCKERS + 1))
else
    echo -e "${GREEN}  No secrets detected in diff.${NC}"
fi

# Check 5: No sensitive files in diff
echo ""
echo -e "${CYAN}[5/10] Checking for sensitive files in diff...${NC}"
SENSITIVE_FILES=false

SENSITIVE_PATTERNS=(
    '\.env$'
    '\.env\.'
    '\.key$'
    '\.pem$'
    '\.p12$'
    '\.pfx$'
    'credentials\.'
    'secrets\.'
    '\.secret$'
    'id_rsa'
    'id_ed25519'
)

CHANGED_FILES=$(cd "$FORK_DIR" && git diff --name-only HEAD~1..HEAD 2>/dev/null || git diff --cached --name-only 2>/dev/null || echo "")

for pattern in "${SENSITIVE_PATTERNS[@]}"; do
    matches=$(echo "$CHANGED_FILES" | grep -E "$pattern" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        echo -e "${RED}  BLOCKER: Sensitive file in diff: $matches${NC}"
        SENSITIVE_FILES=true
    fi
done

if [[ "$SENSITIVE_FILES" == "true" ]]; then
    BLOCKERS=$((BLOCKERS + 1))
else
    echo -e "${GREEN}  No sensitive files in diff.${NC}"
fi

# -----------------------------------------------
# QUALITY CATEGORY
# -----------------------------------------------

# Check 6: Test evidence exists
echo ""
echo -e "${CYAN}[6/10] Checking test evidence...${NC}"
if [[ -f "$ISSUE_DIR/session.md" ]]; then
    if grep -qi "test.*output\|test.*evidence\|tests pass" "$ISSUE_DIR/session.md" 2>/dev/null; then
        echo -e "${GREEN}  Test evidence found in session record.${NC}"
    else
        echo -e "${YELLOW}  WARNING: No test evidence in session record.${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${YELLOW}  WARNING: No session record found at $ISSUE_DIR/session.md${NC}"
    WARNINGS=$((WARNINGS + 1))
fi

# Check 7: Issue spec acceptance criteria
echo ""
echo -e "${CYAN}[7/10] Checking issue spec...${NC}"
if [[ -f "$ISSUE_DIR/spec.md" ]]; then
    if grep -qi "acceptance criteria\|Acceptance Criteria" "$ISSUE_DIR/spec.md" 2>/dev/null; then
        echo -e "${GREEN}  Issue spec has acceptance criteria.${NC}"
    else
        echo -e "${YELLOW}  WARNING: Issue spec missing acceptance criteria.${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${YELLOW}  WARNING: No issue spec found at $ISSUE_DIR/spec.md${NC}"
    WARNINGS=$((WARNINGS + 1))
fi

# -----------------------------------------------
# METHODOLOGY CATEGORY
# -----------------------------------------------

# Check 8: Session record exists
echo ""
echo -e "${CYAN}[8/10] Checking session record...${NC}"
if [[ -f "$ISSUE_DIR/session.md" ]]; then
    echo -e "${GREEN}  Session record exists.${NC}"
else
    echo -e "${YELLOW}  WARNING: No session record. Create: data/issues/$SLUG/session.md${NC}"
    WARNINGS=$((WARNINGS + 1))
fi

# Check 9: Alternatives documented
echo ""
echo -e "${CYAN}[9/10] Checking alternatives documentation...${NC}"
if [[ -f "$ISSUE_DIR/session.md" ]]; then
    if grep -qi "alternatives\|alternative.*considered\|rejected because" "$ISSUE_DIR/session.md" 2>/dev/null; then
        echo -e "${GREEN}  Alternatives documented in session record.${NC}"
    else
        echo -e "${YELLOW}  WARNING: No alternatives documented in session record.${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
elif [[ -f "$ISSUE_DIR/spec.md" ]]; then
    if grep -qi "alternatives\|alternative.*considered" "$ISSUE_DIR/spec.md" 2>/dev/null; then
        echo -e "${GREEN}  Alternatives documented in issue spec.${NC}"
    else
        echo -e "${YELLOW}  WARNING: No alternatives documented.${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${YELLOW}  WARNING: No session record or spec to check.${NC}"
    WARNINGS=$((WARNINGS + 1))
fi

# Check 10: AI disclosure compliance
echo ""
echo -e "${CYAN}[10/10] Checking AI disclosure compliance...${NC}"
case "$AI_DISCLOSURE" in
    forbidden)
        # Check that no AI mentions appear in commits or diff
        AI_MENTION=false
        AI_PATTERNS="co-authored-by.*claude\|co-authored-by.*anthropic\|co-authored-by.*gpt\|co-authored-by.*openai\|generated by.*\bAI\b\|\bAI\b.*assisted\|claude.*code"
        if cd "$FORK_DIR" && git log -1 --format="%B" 2>/dev/null | grep -qi "$AI_PATTERNS"; then
            echo -e "${RED}  BLOCKER: AI mentions found in commits but project forbids AI disclosure${NC}"
            AI_MENTION=true
        fi
        if echo "$DIFF" | grep -qi "co-authored-by.*claude\|co-authored-by.*anthropic" 2>/dev/null; then
            echo -e "${RED}  BLOCKER: AI mentions found in diff but project forbids AI disclosure${NC}"
            AI_MENTION=true
        fi
        if [[ "$AI_MENTION" == "true" ]]; then
            BLOCKERS=$((BLOCKERS + 1))
        else
            echo -e "${GREEN}  No AI mentions found (policy: forbidden).${NC}"
        fi
        ;;
    required)
        # Check that AI disclosure IS present
        if cd "$FORK_DIR" && git log -1 --format="%B" 2>/dev/null | grep -qi "\bAI\b\|claude\|anthropic\|generated\|assisted"; then
            echo -e "${GREEN}  AI disclosure present (policy: required).${NC}"
        else
            echo -e "${RED}  BLOCKER: AI disclosure required but not found in commits.${NC}"
            BLOCKERS=$((BLOCKERS + 1))
        fi
        ;;
    allowed)
        echo -e "${GREEN}  AI disclosure: allowed (no restrictions).${NC}"
        ;;
esac

# -----------------------------------------------
# VERDICT
# -----------------------------------------------
echo ""
echo "==========================================="

if [[ "$BLOCKERS" -gt 0 ]] && [[ "$FORCE" != "true" ]]; then
    echo -e "${RED}VERDICT: BLOCKED ($BLOCKERS blocker(s), $WARNINGS warning(s))${NC}"
    echo ""
    echo "Fix all blockers before submitting PR."
    echo "Use --force to override (not recommended)."
    exit 1
elif [[ "$BLOCKERS" -gt 0 ]] && [[ "$FORCE" == "true" ]]; then
    echo -e "${YELLOW}VERDICT: FORCED through $BLOCKERS blocker(s) and $WARNINGS warning(s)${NC}"
    echo ""
    echo "Proceeding despite blockers (--force used)."
    exit 2
elif [[ "$WARNINGS" -gt 0 ]]; then
    echo -e "${YELLOW}VERDICT: CAUTION ($WARNINGS warning(s))${NC}"
    echo ""
    echo "No blockers, but address warnings for best results:"
    echo "  - Add test evidence to session.md"
    echo "  - Document alternatives considered"
    echo "  - Create issue spec with acceptance criteria"
    exit 2
else
    echo -e "${GREEN}VERDICT: CLEAR — safe to submit PR.${NC}"
    echo ""
    echo "Recommended next steps:"
    echo "  1. Review diff one final time"
    echo "  2. gh pr create --repo $REPO"
    echo "  3. Monitor for review feedback"
    exit 0
fi
