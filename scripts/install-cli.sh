#!/usr/bin/env bash
set -euo pipefail

repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${HOME}/.local"
registry_path="${HOME}/.config/mappedinfo/qoder-agent-runner.json"
config_path=""
profile="default"
repo_url="https://github.com/Mappedinfo/qoder-agent-runner.git"
skip_build=0

usage() {
  cat <<'EOF'
Usage:
  scripts/install-cli.sh [options]

Options:
  --prefix DIR       install prefix; qoder-run goes to DIR/bin/qoder-run
  --registry PATH    registry JSON path
  --config PATH      local qoder config path; defaults to config.local.json when present
  --profile NAME     config profile name; default: default
  --repo-url URL     source repository URL recorded in registry
  --skip-build       reuse existing .build/release/qoder-run
  --help             show this help

The registry stores executable/config paths only. It never stores token values.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      prefix="$2"
      shift 2
      ;;
    --registry)
      registry_path="$2"
      shift 2
      ;;
    --config)
      config_path="$2"
      shift 2
      ;;
    --profile)
      profile="$2"
      shift 2
      ;;
    --repo-url)
      repo_url="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$config_path" && -f "${repo_path}/config.local.json" ]]; then
  config_path="${repo_path}/config.local.json"
fi

if [[ "$skip_build" != "1" ]]; then
  swift build -c release --package-path "$repo_path"
fi

runner_source="${repo_path}/.build/release/qoder-run"
if [[ ! -x "$runner_source" ]]; then
  echo "built qoder-run not found: $runner_source" >&2
  exit 1
fi

bin_dir="${prefix}/bin"
runner_target="${bin_dir}/qoder-run"
mkdir -p "$bin_dir"
install -m 0755 "$runner_source" "$runner_target"
mkdir -p "$(dirname "$registry_path")"

export QODER_RUNNER_REPO_PATH="$repo_path"
export QODER_RUNNER_REPO_URL="$repo_url"
export QODER_RUNNER_EXECUTABLE_PATH="$runner_target"
export QODER_RUNNER_CONFIG_PATH="$config_path"
export QODER_RUNNER_PROFILE="$profile"
export QODER_RUNNER_REGISTRY_PATH="$registry_path"

/usr/bin/python3 - <<'PY'
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

config_path = os.environ["QODER_RUNNER_CONFIG_PATH"].strip()
payload = {
    "schema_version": 1,
    "name": "qoder-agent-runner",
    "source": "install-cli",
    "repo_url": os.environ["QODER_RUNNER_REPO_URL"],
    "repo_path": str(Path(os.environ["QODER_RUNNER_REPO_PATH"]).expanduser().resolve()),
    "executable_path": str(Path(os.environ["QODER_RUNNER_EXECUTABLE_PATH"]).expanduser().resolve()),
    "config_path": str(Path(config_path).expanduser().resolve()) if config_path else None,
    "profile": os.environ["QODER_RUNNER_PROFILE"] or "default",
    "registered_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}
registry_path = Path(os.environ["QODER_RUNNER_REGISTRY_PATH"]).expanduser()
registry_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "runner=${runner_target}"
echo "registry=${registry_path}"
if [[ -n "$config_path" ]]; then
  echo "config=${config_path}"
else
  echo "config="
fi
echo "profile=${profile}"
