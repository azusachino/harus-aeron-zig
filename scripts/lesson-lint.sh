#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERRORS=0

# Extract all LESSON slugs from source code
SLUGS=$(grep -rh '// LESSON(' "$PROJECT_ROOT/src/" 2>/dev/null | sed 's/.*LESSON(\([^)]*\)).*/\1/' | sort -u)
SLUG_COUNT=$(echo "$SLUGS" | wc -l)

# For each slug, check if any docs/tutorial file contains it in its name (case-insensitive substring match)
while IFS= read -r slug; do
    [ -z "$slug" ] && continue

    # Convert slug to lowercase for case-insensitive matching
    slug_lower=$(echo "$slug" | tr '[:upper:]' '[:lower:]')

    # Check if any docs/tutorial file contains this slug (or close variants) in its name
    # Try: exact slug, slug without dashes, slug parts
    found=0

    # Try exact match (case-insensitive)
    if find "$PROJECT_ROOT/docs/tutorial" -type f -iname "*${slug}*" 2>/dev/null | grep -q .; then
        found=1
    fi

    # Try without dashes (e.g., "broadcast-buffer" -> "broadcastbuffer")
    if [ $found -eq 0 ]; then
        slug_nodash=$(echo "$slug" | tr -d '-')
        if find "$PROJECT_ROOT/docs/tutorial" -type f -iname "*${slug_nodash}*" 2>/dev/null | grep -q .; then
            found=1
        fi
    fi

    # Try just first part (e.g., "broadcast-buffer" -> "broadcast")
    if [ $found -eq 0 ]; then
        slug_first=$(echo "$slug" | cut -d'-' -f1)
        if find "$PROJECT_ROOT/docs/tutorial" -type f -iname "*${slug_first}*" 2>/dev/null | grep -q .; then
            found=1
        fi
    fi

    if [ $found -eq 0 ]; then
        echo "MISSING: LESSON($slug) — no matching file in docs/tutorial/"
        ERRORS=$((ERRORS + 1))
    fi
done <<< "$SLUGS"

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "ERROR: $ERRORS LESSON slug(s) have no matching tutorial doc" >&2
    exit 1
fi

echo "lesson-lint: all $SLUG_COUNT LESSON slug(s) verified OK"
