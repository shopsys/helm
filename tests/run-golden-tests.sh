#!/bin/bash
set -e

# Golden (snapshot) tests of the rendered manifests.
# ===================================================
# Each scenario is a self-contained helmfile environments directory; the manifests are
# rendered with `helmfile template` in three variants (continuous deploy, first deploy,
# first deploy with demo data) and compared against expected/ snapshots.
#
# Usage:
#   ./tests/run-golden-tests.sh                  # run all scenarios
#   ./tests/run-golden-tests.sh basic-production # run a single scenario
#   ./tests/run-golden-tests.sh --list           # list scenarios
#   ./tests/run-golden-tests.sh --update         # regenerate expected files
#   ./tests/run-golden-tests.sh --keep-tmp       # keep rendered output for inspection

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCENARIOS_DIR="${SCRIPT_DIR}/golden/scenarios"
TMP_DIR="${SCRIPT_DIR}/tmp"

UPDATE_MODE=0
KEEP_TMP=0
LIST_ONLY=0
SPECIFIC_SCENARIO=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --list|-l) LIST_ONLY=1; shift ;;
        --update|-u) UPDATE_MODE=1; shift ;;
        --keep-tmp|-k) KEEP_TMP=1; shift ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -14
            exit 0
            ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *) SPECIFIC_SCENARIO="$1"; shift ;;
    esac
done

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NO_COLOR='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

if [ $LIST_ONLY -eq 1 ]; then
    echo "Available scenarios:"
    for dir in "${SCENARIOS_DIR}"/*/; do
        name=$(basename "$dir")
        desc=""
        [ -f "${dir}/description.txt" ] && desc=" - $(cat "${dir}/description.txt")"
        echo "  ${name}${desc}"
    done
    exit 0
fi

# Fixed environment simulating CI variables (legacy tests/lib/default-env.sh)
export TAG="v1.0.0"
export STOREFRONT_TAG="v1.0.0"
export CI_REGISTRY="registry.example.com"
export DEPLOY_REGISTER_USER="deploy-user"
export DEPLOY_REGISTER_PASSWORD="deploy-password"
export RABBITMQ_DEFAULT_USER="rabbitmq"
export RABBITMQ_DEFAULT_PASS="rabbitmq-password"
export BASIC_AUTH_PATH="${SCRIPT_DIR}/fixtures/basicHttpAuth"
# Frozen timestamp for deterministic output (legacy FREEZE_TIMESTAMP)
export DEPLOY_TIMESTAMP="1234567890"
unset GCLOUD_DEPLOY

render_variant() {
    local env_name="$1" output_file="$2" first_deploy="$3" demo_data="$4"

    FIRST_DEPLOY="$first_deploy" FIRST_DEPLOY_LOAD_DEMO_DATA="$demo_data" \
        helmfile --quiet -e "$env_name" template --skip-deps > "$output_file"
}

run_scenario() {
    local scenario="$1"
    local scenario_dir="${SCENARIOS_DIR}/${scenario}"

    if [ ! -d "$scenario_dir" ]; then
        echo -e "${RED}[FAIL]${NO_COLOR} Scenario not found: $scenario"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return
    fi

    # The environment name is the single directory inside the scenario's environments/
    local env_name
    env_name=$(find "${scenario_dir}/environments" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)

    echo ""
    echo "Scenario: ${scenario} (environment: ${env_name})"

    local out_dir="${TMP_DIR}/${scenario}"
    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    export SHOPSYS_ENV_DIR="${scenario_dir}/environments"

    render_variant "$env_name" "${out_dir}/continuous.yaml" 0 0
    render_variant "$env_name" "${out_dir}/first-deploy.yaml" 1 0
    render_variant "$env_name" "${out_dir}/first-deploy-with-demo-data.yaml" 1 1

    if [ "$UPDATE_MODE" = "1" ]; then
        rm -rf "${scenario_dir}/expected"
        mkdir -p "${scenario_dir}/expected"
        cp "${out_dir}"/*.yaml "${scenario_dir}/expected/"
        echo -e "${YELLOW}[UPDATED]${NO_COLOR} expected files for ${scenario}"
        return
    fi

    for variant in continuous first-deploy first-deploy-with-demo-data; do
        local expected="${scenario_dir}/expected/${variant}.yaml"
        local actual="${out_dir}/${variant}.yaml"

        if [ ! -f "$expected" ]; then
            echo -e "${YELLOW}[WARN]${NO_COLOR} ${scenario}/${variant}: missing expected file (run with --update)"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            continue
        fi

        if diff -q "$expected" "$actual" > /dev/null 2>&1; then
            echo -e "${GREEN}[PASS]${NO_COLOR} ${scenario}/${variant}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${RED}[FAIL]${NO_COLOR} ${scenario}/${variant}"
            diff -u "$expected" "$actual" | head -80
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    done

    if [ "$KEEP_TMP" != "1" ]; then
        rm -rf "$out_dir"
    fi
}

cd "$PROJECT_ROOT"

echo "Building chart dependencies..."
helm dependency build charts/shopsys-infra > /dev/null 2>&1
helm dependency build charts/shopsys-app > /dev/null 2>&1

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

if [ -n "$SPECIFIC_SCENARIO" ]; then
    run_scenario "$SPECIFIC_SCENARIO"
else
    for dir in "${SCENARIOS_DIR}"/*/; do
        run_scenario "$(basename "$dir")"
    done
fi

if [ "$UPDATE_MODE" = "1" ]; then
    exit 0
fi

echo ""
echo "Passed: ${TESTS_PASSED}, Failed: ${TESTS_FAILED}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Some tests failed!${NO_COLOR}"
    exit 1
fi
echo -e "${GREEN}All tests passed!${NO_COLOR}"
