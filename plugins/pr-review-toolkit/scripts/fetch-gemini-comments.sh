#!/bin/bash
# Fetch Gemini Code Assist review comments from a PR
# Returns JSON array with parsed comment information
#
# Usage: ./fetch-gemini-comments.sh [PR_NUMBER]
# If PR_NUMBER not provided, uses current branch's PR
#
# Output: JSON array with structure:
# [
#   {
#     "id": 123456789,
#     "priority": "high|medium|low",
#     "is_security": true|false,
#     "is_outdated": true|false,
#     "file": "path/to/file.ts",
#     "line": 42,
#     "body": "full comment body",
#     "suggestion": "code suggestion if any",
#     "created_at": "2026-01-26T10:00:00Z"
#   }
# ]

set -euo pipefail

PR_NUMBER="${1:-}"

# If no PR number provided, try to get from current branch
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$("$SCRIPT_DIR/get-pr-number.sh" || echo "")
fi

if [ -z "$PR_NUMBER" ]; then
  echo "Error: No PR number found. Ensure you're on a branch with an open PR or provide PR number." >&2
  exit 1
fi

# Fetch PR review comments (inline code comments)
if ! API_OUTPUT=$(gh api "/repos/{owner}/{repo}/pulls/${PR_NUMBER}/comments" 2>&1); then
  echo "Error: Failed to fetch PR comments: $API_OUTPUT" >&2
  exit 1
fi

# Filter to gemini-code-assist comments and parse them
jq_script='
[
  .[]
  | select(.user.login == "gemini-code-assist[bot]")
  | {
      id: .id,
      priority: (
        if (.body | test("!\\[high\\]")) then "high"
        elif (.body | test("!\\[medium\\]")) then "medium"
        else "low"
        end
      ),
      is_security: (.body | test("!\\[security")),
      is_outdated: (.position == null),
      file: .path,
      line: .line,
      body: .body,
      suggestion: (
        (.body | capture("```suggestion\\n(?<code>[\\s\\S]*?)\\n```"; "m") | .code) // null
      ),
      created_at: .created_at
    }
]
'

echo "$API_OUTPUT" | jq "$jq_script"
