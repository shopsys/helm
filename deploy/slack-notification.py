import requests
from enum import Enum
import os
import subprocess
import re
import sys


class Type(Enum):
    SUCCESS = 0
    ERROR = 1


def get_deploy_changes(last_deployment_commit: str, current_deployment_commit: str) -> list:
    # get changes from git log
    # git log --first-parent master {last_deployment_commit}..{current_deployment_commit} --pretty=format:"%s"
    # and parse it

    try:
        # Run the git log command
        result = subprocess.run(
            ['git', 'log', '--first-parent', f"{last_deployment_commit}..{current_deployment_commit}",
             '--pretty=format:%s'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            text=True
        )
        # Split the output into individual changes
        changes = result.stdout.split('\n')
        formatted_changes = [f"• {parse_change(change)}\n" for change in changes if '!ignore' not in change]
        return formatted_changes
    except subprocess.CalledProcessError as e:
        print(f"Error: {e.stderr}")
        return []


def parse_change(change: str) -> str:
    jira_url = os.getenv('JIRA_URL', None)
    if jira_url is None:
        return change

    match = re.search(r'\[([a-zA-Z0-9]+-\d+)\]', change)
    if match:
        ticket_id = match.group(1)
        link = f"<{jira_url}{ticket_id}|[{ticket_id}]>"
        change = change.replace(f"[{ticket_id}]", link)
    return change


def get_deployed_commit_hash() -> str:
    api_url = f"{os.environ.get('CI_API_V4_URL')}/projects/{os.environ.get('CI_PROJECT_ID')}"
    api_token = os.environ.get('API_TOKEN')

    response = requests.get(f"{api_url}/deployments?environment=production&status=success&sort=desc",
                            headers={'PRIVATE-TOKEN': api_token}, timeout=10).json()

    return response[0]['sha']


def start_deploy() -> None:
    text = f":in_progress: Deployment to production started.\n :gitlab: <{os.getenv('CI_JOB_URL', 'https://example.com')}|View deployment pipeline>"

    message_id = call_slack(text)

    if os.environ.get('SLACK_DISABLE_CHANGES') is not None:
        return

    text = 'There are deploying changes:\n' + ''.join(
        get_deploy_changes(get_deployed_commit_hash(), os.environ.get('CI_COMMIT_SHA')))
    call_slack(text, message_id, unfurl_links=True)


def end_deploy(end_type: Type) -> None:
    if end_type == Type.ERROR:
        text = f":x: Deployment ended with error.\n <https://{os.getenv('DOMAIN_HOSTNAME_1', 'example.com')}|Check your page> and <{os.getenv('CI_JOB_URL', 'https://example.com')}|View deployment pipeline> <!here>"
        call_slack(text)

    else:
        text = ':white_check_mark: Deployment successfully completed'
        call_slack(text)


def call_slack(text: str, message_id: str = None, unfurl_links: bool = False) -> str:
    url = 'https://slack.com/api/chat.postMessage'

    data = {
        'channel': os.environ.get('SLACK_CHANNEL'),
        'text': text,
        'unfurl_links': bool(unfurl_links),
        'unfurl_media': bool(unfurl_links),
    }

    if message_id:
        data['thread_ts'] = message_id

    r = requests.post(url, json=data, headers={'content-type': 'application/json; charset=utf-8',
                                               'Authorization': f"Bearer {os.environ.get('SLACK_TOKEN')}"}, timeout=10)
    response = r.json()

    if not response['ok']:
        print('Error: ' + response['error'])

    return response['ts']


if __name__ == '__main__':
    if os.environ.get('SLACK_TOKEN') is None or os.environ.get('SLACK_CHANNEL') is None:
        print('Error: Missing env variables SLACK_TOKEN or SLACK_CHANNEL')
        sys.exit(0)

    if len(sys.argv) > 1:
        arg = sys.argv[1]
    else:
        print('Error: Missing argument. You can choose one of: start, end, error')
        sys.exit(0)

    if arg == 'start':
        start_deploy()
        sys.exit(0)

    if arg == 'end':
        end_deploy(Type.SUCCESS)
        sys.exit(0)

    if arg == 'error':
        end_deploy(Type.ERROR)
        sys.exit(0)
