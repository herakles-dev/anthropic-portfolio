#!/bin/bash
# comprehend.sh - Tiered comprehension framework for target repos
# Automates knowledge gathering at the right depth for each issue.
#
# Usage:
#   ./scripts/comprehend.sh OWNER/REPO [--tier 0|1|2|3] [--issue NUMBER]
#
# Tiers:
#   0 = Inline    — Read only the files mentioned in the issue (default)
#   1 = Quick     — Fetch key project files (CONTRIBUTING.md, architecture, CI)
#   2 = Deep      — Clone repo, trace call chains, map dependencies
#   3 = Atheneum  — Import docs + code into existing Atheneum RAG system
#
# Exit codes:
#   0 = Success
#   1 = Error (missing args, network failure, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPREHENSION_DIR="$PROJECT_DIR/data/comprehension"
FORKS_DIR="$PROJECT_DIR/data/forks"
ATHENEUM_DIR="$HOME/alan-watts"

# ── Colors ──────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*" >&2; }
header(){ echo -e "\n${CYAN}=== $* ===${NC}"; }

# ── Argument Parsing ────────────────────────────────────────────────────────────

REPO=""
TIER=0
ISSUE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)   TIER="$2";  shift 2 ;;
    --issue)  ISSUE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 OWNER/REPO [--tier 0|1|2|3] [--issue NUMBER]"
      echo ""
      echo "Tiers:"
      echo "  0  Inline    Read specific files only (default)"
      echo "  1  Quick     Fetch key project docs (CONTRIBUTING, README, CI)"
      echo "  2  Deep      Clone repo, trace dependencies, map architecture"
      echo "  3  Atheneum  Import docs/code into existing Atheneum RAG system"
      exit 0
      ;;
    *)
      if [[ -z "$REPO" ]]; then
        REPO="$1"
      else
        err "Unknown argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

[[ -n "$REPO" ]] || { err "OWNER/REPO is required"; exit 1; }
[[ "$TIER" =~ ^[0-3]$ ]] || { err "Tier must be 0, 1, 2, or 3"; exit 1; }

OWNER="${REPO%%/*}"
REPONAME="${REPO##*/}"
SLUG="${OWNER}-${REPONAME}"
COMP_DIR="$COMPREHENSION_DIR/$SLUG"

# ── Tier Detection (auto-escalate if --tier not specified) ──────────────────────

auto_detect_tier() {
  # If user didn't explicitly set tier, suggest based on signals
  if [[ "$TIER" -eq 0 ]] && [[ -n "$ISSUE" ]]; then
    # Check if we already have comprehension data
    if [[ -d "$COMP_DIR" ]] && [[ -f "$COMP_DIR/architecture.md" ]]; then
      info "Existing deep comprehension found for $SLUG — reusing"
      return
    fi

    # Count our past contributions to this repo
    local pr_count
    pr_count=$(gh search prs --author=herakles-dev --repo="$REPO" --json number 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

    if [[ "$pr_count" -ge 3 ]]; then
      warn "You have $pr_count PRs to this repo. Consider --tier 3 (Atheneum) for sustained contributions."
    fi
  fi
}

# ── Tier 0: Inline ──────────────────────────────────────────────────────────────
# Just validates the repo exists and optionally fetches the issue body.
# Actual file reading happens in Claude's context — this tier is a no-op stub.

tier_0_inline() {
  header "Tier 0: Inline Comprehension — $REPO"

  # Verify repo exists
  if ! gh repo view "$REPO" --json name >/dev/null 2>&1; then
    err "Repository $REPO not found or not accessible"
    exit 1
  fi
  ok "Repo verified: $REPO"

  if [[ -n "$ISSUE" ]]; then
    info "Issue #$ISSUE — read the specific files mentioned in the issue body"
    gh issue view "$ISSUE" -R "$REPO" --json title,body,labels | jq -r '"Title: \(.title)\n\nBody:\n\(.body)"'
  fi

  echo ""
  info "Tier 0 complete. Read the files referenced in the issue directly."
  info "Escalate to --tier 1 if you need project-wide context."
}

# ── Tier 1: Quick Scan ──────────────────────────────────────────────────────────
# Fetch key project docs without cloning the full repo.

tier_1_quick() {
  header "Tier 1: Quick Scan — $REPO"

  mkdir -p "$COMP_DIR"

  local files_fetched=0

  # Key files to fetch (in priority order)
  local key_files=(
    "CONTRIBUTING.md"
    "CONTRIBUTING.rst"
    ".github/CONTRIBUTING.md"
    "README.md"
    "ARCHITECTURE.md"
    "docs/ARCHITECTURE.md"
    "CODE_OF_CONDUCT.md"
    ".github/PULL_REQUEST_TEMPLATE.md"
    ".github/pull_request_template.md"
    ".github/ISSUE_TEMPLATE/config.yml"
    "pyproject.toml"
    "package.json"
    "Cargo.toml"
    "go.mod"
    ".github/workflows/ci.yml"
    ".github/workflows/CI.yml"
    ".github/workflows/test.yml"
    ".github/workflows/tests.yml"
    "Makefile"
    "CLAUDE.md"
  )

  for file in "${key_files[@]}"; do
    local safe_name
    safe_name=$(echo "$file" | tr '/' '_')
    local content
    content=$(gh api "repos/$REPO/contents/$file" --jq '.content' 2>/dev/null || true)

    if [[ -n "$content" && "$content" != "null" ]]; then
      echo "$content" | base64 -d > "$COMP_DIR/$safe_name" 2>/dev/null || true
      if [[ -s "$COMP_DIR/$safe_name" ]]; then
        ok "Fetched: $file"
        files_fetched=$((files_fetched + 1))
      else
        rm -f "$COMP_DIR/$safe_name"
      fi
    fi
  done

  # Detect tech stack from fetched files
  local stack="unknown"
  if [[ -f "$COMP_DIR/pyproject.toml" ]]; then
    stack="python"
  elif [[ -f "$COMP_DIR/package.json" ]]; then
    stack="node"
  elif [[ -f "$COMP_DIR/Cargo.toml" ]]; then
    stack="rust"
  elif [[ -f "$COMP_DIR/go.mod" ]]; then
    stack="go"
  fi

  # Detect CI requirements
  local ci_file=""
  for f in ".github_workflows_ci.yml" ".github_workflows_CI.yml" ".github_workflows_test.yml" ".github_workflows_tests.yml"; do
    if [[ -f "$COMP_DIR/$f" ]]; then
      ci_file="$f"
      break
    fi
  done

  # Write summary
  cat > "$COMP_DIR/scan-summary.md" <<EOF
# Quick Scan: $REPO
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Stack: $stack
## Files fetched: $files_fetched

## Key Findings

### Contributing Guide
$(if [[ -f "$COMP_DIR/CONTRIBUTING.md" ]] || [[ -f "$COMP_DIR/.github_CONTRIBUTING.md" ]]; then
    echo "FOUND — Read before submitting any PR"
  elif [[ -f "$COMP_DIR/CONTRIBUTING.rst" ]]; then
    echo "FOUND (RST format) — Read before submitting any PR"
  else
    echo "NOT FOUND — Follow standard GitHub conventions"
  fi)

### CI Pipeline
$(if [[ -n "$ci_file" ]]; then
    echo "FOUND ($ci_file) — Review for required checks"
  else
    echo "Not detected in standard locations"
  fi)

### CLA Required
$(if [[ -f "$COMP_DIR/CONTRIBUTING.md" ]]; then
    if grep -qi "CLA\|contributor license\|signing.*agreement" "$COMP_DIR/CONTRIBUTING.md" 2>/dev/null; then
      echo "YES — Sign CLA before submitting"
    else
      echo "Not mentioned in CONTRIBUTING.md"
    fi
  else
    echo "Unknown (no CONTRIBUTING.md found)"
  fi)

### Commit Conventions
$(if [[ -f "$COMP_DIR/CONTRIBUTING.md" ]]; then
    if grep -qi "conventional commit\|commit message\|commit format" "$COMP_DIR/CONTRIBUTING.md" 2>/dev/null; then
      echo "Mentioned in CONTRIBUTING.md — review for details"
    else
      echo "No specific format mentioned"
    fi
  else
    echo "Unknown"
  fi)

### PR Template
$(if [[ -f "$COMP_DIR/.github_PULL_REQUEST_TEMPLATE.md" ]] || [[ -f "$COMP_DIR/.github_pull_request_template.md" ]]; then
    echo "FOUND — Use their template"
  else
    echo "Not found — Use standard format"
  fi)

### CLAUDE.md
$(if [[ -f "$COMP_DIR/CLAUDE.md" ]]; then
    echo "FOUND — Project has AI-specific instructions (MUST READ)"
  else
    echo "Not found"
  fi)
EOF

  ok "Scan summary: $COMP_DIR/scan-summary.md"
  echo ""
  info "Tier 1 complete. $files_fetched files saved to $COMP_DIR/"
  info "Read scan-summary.md for quick orientation."
  info "Escalate to --tier 2 for call-chain tracing and dependency mapping."
}

# ── Tier 2: Deep Dive ───────────────────────────────────────────────────────────
# Clone the full repo and perform deep analysis.

tier_2_deep() {
  header "Tier 2: Deep Dive — $REPO"

  # Run tier 1 first if not already done
  if [[ ! -d "$COMP_DIR" ]] || [[ ! -f "$COMP_DIR/scan-summary.md" ]]; then
    tier_1_quick
  fi

  # Clone or update the fork
  local clone_dir="$FORKS_DIR/$REPONAME"
  if [[ -d "$clone_dir/.git" ]]; then
    info "Repo already cloned at $clone_dir — pulling latest"
    (cd "$clone_dir" && git fetch --all --quiet 2>/dev/null)
  else
    info "Cloning $REPO..."
    mkdir -p "$FORKS_DIR"
    gh repo fork "$REPO" --clone --remote=true -- "$clone_dir" 2>/dev/null || \
      git clone "https://github.com/$REPO.git" "$clone_dir" 2>/dev/null
  fi

  ok "Repo available at $clone_dir"

  # Directory structure map
  info "Mapping directory structure..."
  (cd "$clone_dir" && find . -type f -name "*.py" -o -name "*.ts" -o -name "*.js" -o -name "*.rs" -o -name "*.go" \
    | grep -v node_modules | grep -v __pycache__ | grep -v .git | grep -v vendor \
    | head -200 | sort) > "$COMP_DIR/source-tree.txt" 2>/dev/null || true

  local src_count
  src_count=$(wc -l < "$COMP_DIR/source-tree.txt" 2>/dev/null || echo "0")
  ok "Source tree: $src_count files mapped"

  # Test pattern detection
  info "Detecting test patterns..."
  local test_files
  test_files=$(cd "$clone_dir" && find . -type f \( -name "test_*.py" -o -name "*_test.py" -o -name "*.test.ts" \
    -o -name "*.test.js" -o -name "*_test.go" -o -name "*_test.rs" \) \
    | grep -v node_modules | grep -v __pycache__ | head -50 | sort)

  if [[ -n "$test_files" ]]; then
    echo "$test_files" > "$COMP_DIR/test-files.txt"
    ok "Test files: $(echo "$test_files" | wc -l) found"
  else
    warn "No test files detected in standard patterns"
  fi

  # Dependency analysis
  info "Analyzing dependencies..."
  if [[ -f "$clone_dir/pyproject.toml" ]]; then
    (cd "$clone_dir" && grep -A 100 '^\[project\]' pyproject.toml 2>/dev/null | \
      grep -A 50 'dependencies' | head -60) > "$COMP_DIR/dependencies.txt" 2>/dev/null || true
  elif [[ -f "$clone_dir/package.json" ]]; then
    (cd "$clone_dir" && jq '{dependencies, devDependencies}' package.json 2>/dev/null) > "$COMP_DIR/dependencies.txt" 2>/dev/null || true
  elif [[ -f "$clone_dir/go.mod" ]]; then
    (cd "$clone_dir" && cat go.mod) > "$COMP_DIR/dependencies.txt" 2>/dev/null || true
  elif [[ -f "$clone_dir/Cargo.toml" ]]; then
    (cd "$clone_dir" && grep -A 100 '\[dependencies\]' Cargo.toml | head -60) > "$COMP_DIR/dependencies.txt" 2>/dev/null || true
  fi

  # If issue specified, trace relevant code paths
  if [[ -n "$ISSUE" ]]; then
    info "Tracing code paths related to issue #$ISSUE..."
    local issue_body
    issue_body=$(gh issue view "$ISSUE" -R "$REPO" --json body --jq '.body' 2>/dev/null || echo "")

    # Extract file paths and symbols from issue body
    local mentioned_files
    mentioned_files=$(echo "$issue_body" | grep -oE '[a-zA-Z0-9_/]+\.(py|ts|js|rs|go)' | sort -u || true)

    if [[ -n "$mentioned_files" ]]; then
      echo "# Files mentioned in issue #$ISSUE" > "$COMP_DIR/issue-traces.txt"
      echo "$mentioned_files" >> "$COMP_DIR/issue-traces.txt"
      echo "" >> "$COMP_DIR/issue-traces.txt"

      # For each mentioned file, find imports/references
      # Try both direct path and common prefixes (src/, lib/, pkg/)
      while IFS= read -r mfile; do
        local found_path=""
        for prefix in "" "src/" "lib/" "pkg/" "packages/"; do
          if [[ -f "$clone_dir/${prefix}${mfile}" ]]; then
            found_path="$clone_dir/${prefix}${mfile}"
            break
          fi
        done

        if [[ -n "$found_path" ]]; then
          echo "## $mfile — imports:" >> "$COMP_DIR/issue-traces.txt"
          grep -n "^import\|^from\|require(\|use " "$found_path" 2>/dev/null | head -20 >> "$COMP_DIR/issue-traces.txt" || true
          echo "" >> "$COMP_DIR/issue-traces.txt"
        fi
      done <<< "$mentioned_files"
      ok "Code traces saved for $(echo "$mentioned_files" | wc -l) files"
    fi
  fi

  # Write deep analysis summary
  cat > "$COMP_DIR/deep-summary.md" <<EOF
# Deep Dive: $REPO
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Clone: $clone_dir

## Source Files: $src_count
## Test Files: $(wc -l < "$COMP_DIR/test-files.txt" 2>/dev/null || echo "0")

## Artifacts
- source-tree.txt — All source files
- test-files.txt — Test file locations
- dependencies.txt — Project dependencies
$(if [[ -n "$ISSUE" && -f "$COMP_DIR/issue-traces.txt" ]]; then echo "- issue-traces.txt — Code paths for issue #$ISSUE"; fi)
- scan-summary.md — Tier 1 quick scan

## Next Steps
1. Read the files in issue-traces.txt to understand the code area
2. Check test-files.txt for existing test patterns to follow
3. Review dependencies.txt for version constraints
4. If contributing to this repo 3+ times, escalate to --tier 3
EOF

  ok "Deep summary: $COMP_DIR/deep-summary.md"
  echo ""
  info "Tier 2 complete. Full analysis at $COMP_DIR/"
  info "Escalate to --tier 3 to import into Atheneum for semantic search — recommended after 3+ PRs to same repo."
}

# ── Tier 3: Atheneum Import ──────────────────────────────────────────────────────
# Import repo docs/code into the existing Atheneum RAG system at ~/alan-watts/.
# No fork needed — the Atheneum is a multi-source system. Each repo becomes a
# new source in the existing DB (sources → transcripts → chunks → embeddings).

tier_3_atheneum() {
  header "Tier 3: Atheneum Import — $REPO"

  # Run tier 2 first if not already done
  if [[ ! -f "$COMP_DIR/deep-summary.md" ]]; then
    tier_2_deep
  fi

  local clone_dir="$FORKS_DIR/$REPONAME"

  # Verify Atheneum exists
  if [[ ! -d "$ATHENEUM_DIR/src/ingestion" ]]; then
    err "Atheneum not found at $ATHENEUM_DIR"
    err "The alan-watts RAG library must be set up first."
    exit 1
  fi

  # Check if source already registered
  source ~/.secrets/hercules.env 2>/dev/null || true
  local db_url
  db_url=$(python3 -c "
import sys; sys.path.insert(0, '$ATHENEUM_DIR')
from config.settings import DATABASE_URL
print(DATABASE_URL)
" 2>/dev/null || echo "")

  if [[ -n "$db_url" ]]; then
    local existing
    existing=$(python3 -c "
import psycopg2
conn = psycopg2.connect('$db_url')
cur = conn.cursor()
cur.execute(\"SELECT COUNT(*) FROM sources WHERE name = %s\", ('$REPO',))
print(cur.fetchone()[0])
conn.close()
" 2>/dev/null || echo "0")

    if [[ "$existing" -gt 0 ]]; then
      ok "Source '$REPO' already imported into Atheneum"
      info "To re-import, delete the source first or add new files."
      info "Query: curl http://localhost:8131/api/search?q=YOUR+QUERY"
      info "MCP:   cd $ATHENEUM_DIR && make mcp"
      return
    fi
  fi

  # Collect docs and key source files to import
  local import_dir="$COMP_DIR/atheneum-import"
  mkdir -p "$import_dir"

  info "Collecting docs and key source files for import..."

  # Copy key documentation
  local doc_count=0
  for doc in README.md CONTRIBUTING.md ARCHITECTURE.md CLAUDE.md CHANGELOG.md; do
    if [[ -f "$clone_dir/$doc" ]]; then
      cp "$clone_dir/$doc" "$import_dir/$doc"
      doc_count=$((doc_count + 1))
    fi
  done

  # Copy docs/ directory if it exists
  if [[ -d "$clone_dir/docs" ]]; then
    find "$clone_dir/docs" -name "*.md" -o -name "*.rst" -o -name "*.txt" | head -50 | while IFS= read -r f; do
      local rel_name
      rel_name=$(echo "$f" | sed "s|$clone_dir/||" | tr '/' '_')
      cp "$f" "$import_dir/$rel_name"
      doc_count=$((doc_count + 1))
    done
  fi

  ok "Collected $doc_count documentation files"

  # Import into Atheneum using its existing loader infrastructure
  info "Importing into Atheneum as source: $REPO"

  python3 - "$ATHENEUM_DIR" "$REPO" "$import_dir" "$clone_dir" <<'PYEOF'
import sys, os, hashlib, re

atheneum_dir = sys.argv[1]
repo = sys.argv[2]
import_dir = sys.argv[3]
clone_dir = sys.argv[4]

sys.path.insert(0, atheneum_dir)
from config.settings import DATABASE_URL
from src.ingestion.loader import get_connection, ensure_source, insert_transcript

conn = get_connection()

# Register the repo as a source
source_id = ensure_source(
    conn,
    name=repo,
    url=f"https://github.com/{repo}",
    source_type="github"
)
print(f"[OK] Source registered: {repo} (id={source_id})")

# Import documentation files
imported = 0
skipped = 0
for fname in sorted(os.listdir(import_dir)):
    fpath = os.path.join(import_dir, fname)
    if not os.path.isfile(fpath):
        continue
    text = open(fpath, encoding="utf-8", errors="replace").read()
    if not text.strip():
        continue

    tid = insert_transcript(
        conn,
        source_id=source_id,
        title=fname,
        full_text=text,
        series=repo,
        metadata={"type": "documentation", "file": fname}
    )
    if tid:
        imported += 1
    else:
        skipped += 1

print(f"[OK] Imported: {imported} docs, Skipped (dupes): {skipped}")
conn.close()
PYEOF

  if [[ $? -eq 0 ]]; then
    ok "Import complete"
  else
    warn "Import had errors — check output above"
  fi

  # Record import metadata
  cat > "$COMP_DIR/atheneum-source.md" <<EOF
# Atheneum Source: $REPO
Imported: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Access
- API: http://localhost:8131/api/search?q=YOUR+QUERY
- MCP: cd ~/alan-watts && make mcp
- Filter by series: GET /api/transcripts?series=$REPO

## What's Imported
- Documentation files (README, CONTRIBUTING, ARCHITECTURE, docs/)
- Source: https://github.com/$REPO

## Re-import
To update after major repo changes:
1. Delete existing source: DELETE FROM sources WHERE name = '$REPO'
2. Re-run: ./scripts/comprehend.sh $REPO --tier 3

## Chunking & Embedding
After import, run the Atheneum pipeline to chunk and embed:
  cd ~/alan-watts && source ~/.secrets/hercules.env
  make run-pipeline
EOF

  echo ""
  info "Tier 3 complete. $REPO imported into Atheneum."
  info "Query: curl http://localhost:8131/api/search?q=YOUR+QUERY"
  info "MCP:   cd $ATHENEUM_DIR && make mcp"
  info "Run 'make run-pipeline' in $ATHENEUM_DIR to chunk + embed the new docs."
}

# ── Main ────────────────────────────────────────────────────────────────────────

auto_detect_tier

header "Comprehension Tier $TIER for $REPO"

case "$TIER" in
  0) tier_0_inline ;;
  1) tier_1_quick ;;
  2) tier_2_deep ;;
  3) tier_3_atheneum ;;
esac

echo ""
echo -e "${GREEN}Comprehension artifacts:${NC} $COMP_DIR/"
