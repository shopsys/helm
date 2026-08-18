#!/bin/bash
# Shared functions of the deploy wrapper (ported from the legacy shopsys/deployment package).

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
NO_COLOR='\e[39m'

function assertVariable() {
    var="$1"
    if [ -n "${!var}" ]; then
        return
    else
        echo "Variable $1 is not set"
        return 2
    fi
}

function slack_notification() {
    if [ -n "${SLACK_CHANNEL}" ]; then
        python "$(dirname "${BASH_SOURCE[0]}")/../slack-notification.py" "$1"
    fi
}

# runCommand <ERROR|SKIP|FAILED> <command>
#   ERROR:  print output, notify slack, exit 1 on failure
#   SKIP:   yellow note, continue (expected-failure steps, e.g. resource already exists)
#   FAILED: yellow note, continue (non-blocking steps)
function runCommand() {
    if LAST_COMMAND_OUTPUT=$(eval "${2} 2>&1" 2>&1)
    then
        echo -e "[${GREEN}OK${NO_COLOR}]"
    else
        if [ "$1" == "ERROR" ]; then
            echo -e "[${RED}ERROR${NO_COLOR}]"
            echo ""
            echo "${LAST_COMMAND_OUTPUT}"
            slack_notification "error"
            exit 1
        else
            echo -e "[${YELLOW}${1}${NO_COLOR}]"
        fi
    fi
}

# section_start/section_end: GitLab CI collapsible log sections
function section_start() {
    echo -e "section_start:$(date +%s):${1}\r\e[0K${2}"
}

function section_end() {
    echo -e "section_end:$(date +%s):${1}\r\e[0K"
}

# Install package for slack notification
if [ -n "${SLACK_CHANNEL}" ]; then
    pip install requests > /dev/null 2>&1 || pip3 install requests > /dev/null 2>&1 || true
fi
