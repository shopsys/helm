#!/bin/bash
set -e

# Semantic parity check: new helmfile render vs legacy shopsys/deployment snapshots.
# ==================================================================================
# Compares resources with the same kind/name after canonicalization:
#   - keys sorted recursively, env lists sorted by name
#   - namespace, helm hook annotations, checksum annotations and kustomize configmap
#     name hashes are stripped (documented deviations, see docs/migrating-from-shopsys-deployment.md)
#
# Usage: LEGACY_REPO=/path/to/shopsys-deployment ./tools/compare-legacy.sh [scenario]
# The legacy repo must contain tests/scenarios/<scenario>/expected/ snapshots.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LEGACY_REPO="${LEGACY_REPO:?Set LEGACY_REPO to a clone of shopsys/deployment}"
SCENARIO="${1:-basic-production}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Render the new manifests (continuous deploy variant)
cd "$PROJECT_ROOT"
./tests/run-golden-tests.sh --keep-tmp "$SCENARIO" > /dev/null 2>&1 || true
NEW_RENDER="$PROJECT_ROOT/tests/tmp/$SCENARIO/continuous.yaml"
if [ ! -f "$NEW_RENDER" ]; then
    echo "New render not found: $NEW_RENDER" >&2
    exit 1
fi

canonicalize() {
    # $1: input multi-doc yaml, $2: output directory (one file per kind_name)
    local input="$1" outdir="$2"
    mkdir -p "$outdir"

    local count
    count=$(grep -c '^kind:\|^---' "$input" || true)
    count=$((count + 2))
    for ((d = 0; d < count; d++)); do
        local kind name
        kind=$(yq "select(documentIndex == $d) | .kind // \"\"" "$input" 2>/dev/null | head -1)
        name=$(yq "select(documentIndex == $d) | .metadata.name // \"\"" "$input" 2>/dev/null | head -1)
        [ -z "$kind" ] || [ "$kind" = "null" ] && continue
        [[ "$name" == domains-urls-* && "$name" != domains-urls-hook ]] && name="domains-urls"
        yq "select(documentIndex == $d)" "$input" \
            | yq '.metadata.name |= sub("^domains-urls-[a-z0-9]{8,}$"; "domains-urls")
                | del(.metadata.namespace)
                | (.metadata.labels | select(. != null)) |= with_entries(select(.key | test("^(app\.kubernetes\.io/|helm\.sh/)") | not))
                | del(.metadata.labels | select(length == 0))
                | del(.metadata.annotations."helm.sh/hook")
                | del(.metadata.annotations."helm.sh/hook-weight")
                | del(.metadata.annotations."helm.sh/hook-delete-policy")
                | (.spec.template.metadata.annotations | select(. != null)) |= with_entries(select(.key | test("^checksum/") | not))
                | (.spec.template.spec.containers[]? | select(.env != null) | .env) |= sort_by(.name)
                | (.spec.template.spec.volumes[]? | select(.configMap.name != null) | .configMap.name) |= sub("^domains-urls.*$"; "domains-urls")
                | sort_keys(..)' \
            | yq -o=json | yq -P \
            > "$outdir/${kind}_${name}.yaml" 2>/dev/null || true
    done
}

echo "Canonicalizing legacy snapshots..."
LEGACY_DIR="$WORK_DIR/legacy"
mkdir -p "$LEGACY_DIR"
for f in "$LEGACY_REPO/tests/scenarios/$SCENARIO/expected/"*.yaml; do
    # Skip first-deploy variants - compare the continuous one only
    case "$(basename "$f")" in
        migrate-first-deploy*.yaml) continue ;;
    esac
    canonicalize "$f" "$LEGACY_DIR"
done

echo "Canonicalizing new render..."
NEW_DIR="$WORK_DIR/new"
canonicalize "$NEW_RENDER" "$NEW_DIR"

echo ""
echo "=== Diffs of resources present in BOTH renders ==="
DIFFERENT=0
for legacy_file in "$LEGACY_DIR"/*.yaml; do
    base=$(basename "$legacy_file")
    new_file="$NEW_DIR/$base"
    if [ -f "$new_file" ]; then
        if ! diff -u "$legacy_file" "$new_file" > "$WORK_DIR/diff.txt" 2>&1; then
            DIFFERENT=$((DIFFERENT + 1))
            echo ""
            echo "--- DIFF: $base ---"
            cat "$WORK_DIR/diff.txt"
        else
            echo "MATCH: $base"
        fi
    fi
done

echo ""
echo "=== Only in legacy ==="
for f in "$LEGACY_DIR"/*.yaml; do
    [ -f "$NEW_DIR/$(basename "$f")" ] || echo "  $(basename "$f")"
done
echo "=== Only in new ==="
for f in "$NEW_DIR"/*.yaml; do
    [ -f "$LEGACY_DIR/$(basename "$f")" ] || echo "  $(basename "$f")"
done

exit 0
