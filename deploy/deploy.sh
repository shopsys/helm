#!/bin/bash -e

# Shopsys Platform deploy wrapper
# ===============================
# Usage: ./deploy/deploy.sh <environment>
#
# Orchestration happens in helmfile + helm hooks; this wrapper only keeps the steps
# Helm genuinely cannot do, preserving all legacy end states:
#   1. slack "start" notification
#   2. namespace + one-time fe-api-keys secret (openssl)
#   3. optional configuration print (DISPLAY_FINAL_CONFIGURATION=1)
#   4. helmfile apply  (infra release -> cron-suspend -> migrate-application ->
#                       manifests + rollout wait -> post-deploy)
#   5. on failure: restore crons on the old code, disable the maintenance page,
#      print migration logs, slack "error", exit 1
#   6. on success: print migration + post-deploy logs
#   7. website check of every domain (200 OK / 401 skip / otherwise error)
#   8. slack "end" notification
#
# Environment variables consumed here and by environments/runtime.yaml.gotmpl:
#   TAG, STOREFRONT_TAG                      application images (full references)
#   REGISTRY_SERVER/USERNAME/PASSWORD/EMAIL  registry credentials (any registry);
#     GitLab fallback: CI_REGISTRY + DEPLOY_REGISTER_USER/PASSWORD
#   RABBITMQ_DEFAULT_USER, RABBITMQ_DEFAULT_PASS
#   FIRST_DEPLOY, FIRST_DEPLOY_LOAD_DEMO_DATA
#   DISPLAY_FINAL_CONFIGURATION              1 = print rendered manifests
#   DISABLE_WEBSITE_RUNNING_CHECK            true = skip the website check
#
# HTTP basic auth is configured purely in values (security.httpAuth.username/password
# or existingSecret); the website check reads the credentials from the deployed release.
#   SLACK_TOKEN, SLACK_CHANNEL, ...          slack notification (see docs)
#   HELMFILE_EXTRA_ARGS                      extra arguments appended to helmfile commands

BASE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASE_PATH}/deploy/lib/functions.sh"

ENVIRONMENT="${1:?Usage: deploy.sh <environment>}"

assertVariable "TAG"
assertVariable "STOREFRONT_TAG"

export DEPLOY_TIMESTAMP="${DEPLOY_TIMESTAMP:-$(date +%s)}"

HELMFILE=(helmfile -e "${ENVIRONMENT}" --file "${BASE_PATH}/helmfile.yaml.gotmpl")
if [ -n "${HELMFILE_EXTRA_ARGS}" ]; then
    # shellcheck disable=SC2206
    HELMFILE+=(${HELMFILE_EXTRA_ARGS})
fi

echo -n "Resolve target namespace "
NAMESPACE=$("${HELMFILE[@]}" list --output json 2>/dev/null | yq '.[0].namespace')
if [ -z "${NAMESPACE}" ] || [ "${NAMESPACE}" = "null" ]; then
    echo -e "[${RED}ERROR${NO_COLOR}] Unable to resolve namespace for environment '${ENVIRONMENT}'"
    exit 1
fi
echo -e "[${GREEN}OK${NO_COLOR}] ${NAMESPACE}"

slack_notification "start"

echo "Prepare namespace to run project:"

echo -n "    Create namespace "
runCommand "SKIP" "kubectl create namespace ${NAMESPACE}"

# One-time generation of the FE API keypair (helm cannot derive a public key,
# and lookup() is empty under `helm template`, so this stays imperative)
if ! kubectl -n "${NAMESPACE}" get secret fe-api-keys > /dev/null 2>&1; then
    KEY_DIR=$(mktemp -d)
    trap 'rm -rf "${KEY_DIR}"' EXIT
    echo -n "    Create Private Key for FE API "
    runCommand "ERROR" "openssl genrsa -out \"${KEY_DIR}/private.key\""
    echo -n "    Create Public Key for FE API "
    runCommand "ERROR" "openssl rsa -in \"${KEY_DIR}/private.key\" -pubout -out \"${KEY_DIR}/public.key\""
    echo -n "    Create secret with generated keys for FE API "
    runCommand "ERROR" "kubectl create secret generic fe-api-keys --from-file=private.key=\"${KEY_DIR}/private.key\" --from-file=public.key=\"${KEY_DIR}/public.key\" -n ${NAMESPACE}"
fi

if [ "${DISPLAY_FINAL_CONFIGURATION:-0}" -eq "1" ]; then
    echo -n "Show configuration "
    runCommand "ERROR" "${HELMFILE[*]} template"
    section_start "final_configuration" "Configuration"
    echo "${LAST_COMMAND_OUTPUT}"
    section_end "final_configuration"
fi

print_job_logs() {
    local job="$1" title="$2"
    if kubectl -n "${NAMESPACE}" get "job/${job}" > /dev/null 2>&1; then
        section_start "${job//-/_}_logs" "${title}"
        kubectl logs "job/${job}" --namespace="${NAMESPACE}" || true
        section_end "${job//-/_}_logs"
    fi
}

echo "Deploy application (helmfile apply):"
set +e
HELMFILE_OUTPUT=$("${HELMFILE[@]}" apply 2>&1)
HELMFILE_EXIT_CODE=$?
set -e
echo "${HELMFILE_OUTPUT}"

if [ ${HELMFILE_EXIT_CODE} -ne 0 ]; then
    MIGRATION_FAILED=$(kubectl -n "${NAMESPACE}" get job migrate-application \
        -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)

    if [ "${MIGRATION_FAILED}" = "True" ]; then
        echo -e "Migration failed [${RED}ERROR${NO_COLOR}]"

        # Restore crons on the previous application version (cron-suspend scaled them to 0)
        echo -n "Restore previous cron container "
        runCommand "SKIP" "kubectl scale deployment/cron --replicas=1 --namespace=${NAMESPACE}"

        RUNNING_WEBSERVER_PHP_FPM_POD=$(kubectl get pods --namespace="${NAMESPACE}" \
            --field-selector=status.phase=Running -l app=webserver-php-fpm \
            -o=jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

        if [ -n "${RUNNING_WEBSERVER_PHP_FPM_POD}" ]; then
            echo -n "Disable Maintenance page if exists "
            runCommand "SKIP" "kubectl exec ${RUNNING_WEBSERVER_PHP_FPM_POD} --namespace=${NAMESPACE} -- ./phing maintenance-off"
        fi

        print_job_logs "migrate-application" "Logs from migration application"
    else
        echo -e "Deploy failed after successful migration (rollout or post-deploy) [${RED}ERROR${NO_COLOR}]"
        print_job_logs "migrate-application" "Logs from migration application"
        print_job_logs "post-deploy" "Logs from post-deploy tasks"
    fi

    slack_notification "error"
    exit 1
fi

print_job_logs "migrate-application" "Logs from migration application"
print_job_logs "post-deploy" "Logs from post-deploy tasks"

# Website check: domain URLs and their HTTP auth state are read from the rendered
# manifests, and the auth credentials from the deployed release values - the check
# always matches what was actually deployed.
if [ "${DISABLE_WEBSITE_RUNNING_CHECK:-false}" = "false" ]; then
    RENDERED=$("${HELMFILE[@]}" template --skip-deps 2>/dev/null)

    DOMAIN_URLS=$(echo "${RENDERED}" \
        | yq eval-all 'select(.kind == "ConfigMap" and .metadata.name == "domains-urls") | .data.*' - \
        | yq '.domains_urls[].url' -)

    AUTH_HOSTS=$(echo "${RENDERED}" \
        | yq eval-all 'select(.kind == "Ingress" and (.metadata.annotations."nginx.ingress.kubernetes.io/auth-type" == "basic")) | .spec.rules[0].host' -)

    AUTH_USER=$(helm get values shopsys-app -n "${NAMESPACE}" --all -o yaml 2>/dev/null | yq '.security.httpAuth.username // ""')
    AUTH_PASSWORD=$(helm get values shopsys-app -n "${NAMESPACE}" --all -o yaml 2>/dev/null | yq '.security.httpAuth.password // ""')

    for URL in ${DOMAIN_URLS}; do
        HOSTNAME_ONLY=$(echo "${URL}" | sed 's|https://||; s|/.*||')
        echo -n "Check if website is running (${URL}) "

        if echo "${AUTH_HOSTS}" | grep -qx "${HOSTNAME_ONLY}" && [ -n "${AUTH_USER}" ] && [ -n "${AUTH_PASSWORD}" ]; then
            CURL_RETURN_CODE=$(curl --user "${AUTH_USER}:${AUTH_PASSWORD}" -L -s -o /dev/null -w "%{http_code}" "${URL}")
        else
            # No credentials known (e.g. existingSecret) - a 401 response ends as SKIP below
            CURL_RETURN_CODE=$(curl -L -s -o /dev/null -w "%{http_code}" "${URL}")
        fi

        if [ "${CURL_RETURN_CODE}" -eq "200" ]; then
            echo -e "[${GREEN}OK${NO_COLOR}]"
        elif [ "${CURL_RETURN_CODE}" -eq "401" ]; then
            echo -e "[${YELLOW}SKIP${NO_COLOR}]"
            echo ""
            echo "URL could not be checked due to custom HTTP auth. Please check URL manually: ${URL}"
        else
            echo -e "[${RED}ERROR${NO_COLOR}]"
            slack_notification "error"
            exit 1
        fi
    done
fi

slack_notification "end"
