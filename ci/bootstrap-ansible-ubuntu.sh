#!/usr/bin/env bash
# One-time prereq on the existing EC2 host, run ONLY after confirming Ubuntu 22.04.
set -euo pipefail
if [[ $(id -u) -ne 0 ]]; then echo 'Run as root via sudo.' >&2; exit 1; fi
. /etc/os-release
if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 22.04 ]]; then
  echo "Unsupported image: ${PRETTY_NAME:-unknown}. Stop; do not change host packages." >&2
  exit 1
fi
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ansible git python3
ansible --version | head -n 1
