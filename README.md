# Qoder Agent Runner

Small native macOS runner for one-shot Qoder agent reports.

## Configure

Copy the example config and fill in your local values:

```bash
cp config.example.json config.local.json
```

`config.local.json` is ignored by git. Keep real agent IDs, environment IDs, output folders, and secrets there or in your shell environment.

Example local config shape:

```json
{
  "active_profile": "default",
  "profiles": {
    "default": {
      "base_url": "https://api.qoder.com.cn/api/v1/cloud",
      "agent_id": "your-agent-id",
      "agent_version": 1,
      "environment_id": "your-environment-id",
      "output_root": "~/QoderRuns",
      "token_env": "QODER_PAT",
      "env_file": ".env"
    }
  }
}
```

The token itself is read from the environment variable named by `token_env`, or from `env_file` when the process environment does not contain that variable. If `env_file` is omitted, the runner automatically checks for `.env` next to `config.local.json`. The UI also provides a temporary token field for one run; it is not written to config. The default API base URL remains `https://api.qoder.com.cn/api/v1/cloud`; override `base_url` per profile when needed.

## Build

```bash
swift build
```

## Install / Register

`qoder-run` is the CLI product built by this repository. Install it into a user-local bin directory and register it for tools such as `academic-harness`:

```bash
./scripts/install-cli.sh
```

By default this installs `qoder-run` to `~/.local/bin/qoder-run` and writes a secret-free registry file at `~/.config/mappedinfo/qoder-agent-runner.json`. The registry stores only executable/config paths, repo metadata, and the selected profile. It never stores token values.

Useful options:

```bash
./scripts/install-cli.sh --prefix ~/.local --config config.local.json --profile default
./scripts/install-cli.sh --registry ~/.config/mappedinfo/qoder-agent-runner.json
```

## CLI

```bash
swift run qoder-run --prompt "调研推理时扩展与更大预训练模型在推理任务上的现状对比。"
swift run qoder-run --prompt-file /path/to/prompt.md
swift run qoder-run --config config.local.json --profile default --prompt-file /path/to/prompt.md
swift run qoder-run --prompt-file /path/to/prompt.md --run-id run_001 --metadata project_id=demo --metadata task_id=task_001
swift run qoder-run --config config.local.json --profile default --check-config
```

Each run writes a timestamped folder under the configured `output_root`, unless `--run-id` or `--run-dir` is supplied.

Run outputs include:

- `report.md`: primary generated document. When the agent writes an artifact, this is copied from the `Write` tool content.
- `summary.md`: final assistant summary message.
- `artifacts/`: every file emitted through the `Write` tool.
- `events.sse`, `events.jsonl`, `session.json`, `prompt.txt`, and `metadata.json`.

## macOS App

```bash
swift run QoderRunnerApp
```

For a double-clickable app bundle:

```bash
./scripts/build-app.sh
open dist/QoderRunner.app
```

Packaging is intentionally local-only; this repository does not require GitHub Actions.

The app clears common proxy environment variables and uses a `URLSession` configuration with no proxy dictionary. This disables app-level proxy use, but it cannot bypass OS-level TUN/VPN routing.
