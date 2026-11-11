#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 1 && "$1" == "--help" ]]; then
    printf 'Usage: bash %s JENKINS_AGENT_USER\n' "$0"
    printf 'Run on the Ubuntu Jenkins agent from an account with sudo access.\n'
    exit 0
fi

if [[ $# -ne 1 || ! ${1:-} =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]; then
    printf 'Usage: bash %s JENKINS_AGENT_USER\n' "$0" >&2
    exit 2
fi

if ! command -v ansible-playbook >/dev/null; then
    printf 'Install Ansible Core before running this script.\n' >&2
    exit 1
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec ansible-playbook -i localhost, "$repo_root/ansible/configure-jenkins-agent.yml" \
    -e "jenkins_agent_user=$1"
