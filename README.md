# opencode-local-llama

<!-- KEYWORDS: opencode, plugin, llama.cpp, local-llm, windows -->
<!-- LANGUAGES: TypeScript, PowerShell -->
<!-- TECHNOLOGY: llama.cpp, CUDA -->
<!-- STATUS -->
**Active**

## About

<!-- DESCRIPTION START -->
An OpenCode v2 plugin that runs a local llama.cpp server as an OpenAI-compatible provider on Windows. The package ships the PowerShell kit framework, scaffolds it into a writable data directory on first run, starts llama-server on demand, registers the models it serves, supervises crashes, and tears it down with the hosting process. No model is bundled or downloaded.
<!-- DESCRIPTION END -->

### Why

<!-- WHY START -->
Keeps local inference private and free of per-token cost: weights stay in a folder you control, the server loads a model only when a request arrives, and VRAM is released after an idle period instead of staying resident. Configuration is split by purpose: machine paths and port in the kit's config.json, per-model settings in models.json next to the weights.
<!-- WHY END -->

## Features

- Scaffolds the bundled kit into `%LOCALAPPDATA%\opencode-local-llama\kit` on first run; existing files are never overwritten, so upgrades add scripts without clobbering edits.
- Starts `llama-server` when OpenCode starts and adopts an already-running server instead of starting a second one.
- Registers models from `GET /v1/models` (router mode lists every GGUF in the models folder); ids and context windows come from the server, not from plugin config.
- Seeds ids from `models.json` at activation so a cold start can resolve `-m local-llama/<id>` before discovery completes.
- Restarts crashes with escalating backoff; GPU/OOM errors detected in the server log skip retries and enter cooldown.
- Stops the server when the hosting process exits, including via an orphaned PowerShell watchdog when plugin cleanup does not run.
- Optional per-model label and limit overrides through plugin options.

## Requirements

- Windows 10/11. The kit lifecycle is PowerShell plus CUDA binaries; other platforms are rejected at activation.
- OpenCode v2.
- NVIDIA GPU with a CUDA 12.4+ driver (`nvidia-smi` works) and enough VRAM for the model you choose.
- `curl.exe` (bundled with Windows) for the kit's fetch script.

## Installation

```sh
opencode plugin add github:LeHuman/opencode-local-llama
```

The command adds the package to the global config. Add options in `opencode.jsonc`:

```jsonc
{
  "plugins": [
    {
      "package": "github:LeHuman/opencode-local-llama",
      "options": {
        "port": 5514,
        "modelsPath": "F:/models"
      }
    }
  ]
}
```

On first start the plugin creates the kit at `%LOCALAPPDATA%\opencode-local-llama\kit` and writes its `config.json`. Fetch the llama.cpp binaries once:

```powershell
powershell -File "$env:LOCALAPPDATA\opencode-local-llama\kit\scripts\fetch.ps1"
```

Then add models: put `.gguf` files in the models folder (`modelsPath`, or the kit's `models` directory) and add an entry per file to `models.json` beside them:

```json
{
  "models": {
    "My-Model-Q5_K_M": {
      "alias": "My-Model",
      "context": 65536,
      "kvQuant": "q4_0",
      "gpuLayers": 99,
      "parallel": 1,
      "chatTemplate": "my-template.jinja"
    }
  }
}
```

`context`, `kvQuant`, `gpuLayers` and `parallel` are required per model. `alias`, `chatTemplate`, `temperature` and `topP` are optional; sampling falls back to `defaults` in the kit's `config.json`, and a `chatTemplate` path resolves against the models folder first. Restart OpenCode after adding a model — the router scans the folder at startup.

Models can also be downloaded explicitly:

```powershell
powershell -File "$env:LOCALAPPDATA\opencode-local-llama\kit\scripts\fetch.ps1" -Gguf <url> -FileName model.gguf
```

## Usage

Select the provider and model in OpenCode, or pass it per run:

```sh
opencode run -m local-llama/My-Model "hello"
```

The kit scripts also run standalone against the scaffolded kit:

```powershell
powershell -File "$env:LOCALAPPDATA\opencode-local-llama\kit\scripts\serve-up.ps1"
powershell -File "$env:LOCALAPPDATA\opencode-local-llama\kit\scripts\status.ps1"
powershell -File "$env:LOCALAPPDATA\opencode-local-llama\kit\scripts\serve-down.ps1"
```

## Configuration

Plugin options, all optional:

| Option | Default | Meaning |
| --- | --- | --- |
| `kitPath` | — | Existing kit folder; skips scaffolding |
| `dataDir` | `%LOCALAPPDATA%\opencode-local-llama` | Where the scaffolded kit lives |
| `binPath` | kit's `build\tools` | Folder containing `llama-server.exe`; written to the kit's `config.json` |
| `modelsPath` | kit's `models` | Folder containing GGUFs and `models.json`; written to the kit's `config.json` |
| `host` | `127.0.0.1` | Server bind address |
| `port` | `5514` | Server port |
| `providerID` | `local-llama` | Provider id used as `<providerID>/<model>` |
| `providerName` | `Local llama.cpp` | Display name in the model picker |
| `startTimeoutMs` | `180000` | Max wait for `/health` after spawn |
| `defaultContext` | `65536` | Fallback context when the server reports none |
| `defaultOutput` | `16384` | Advertised max output tokens |
| `models` | `{}` | Per-model overrides: `{ name, context, output }` |
| `supervise` | `true` | Crash-watch and restart |
| `maxRestarts` | `3` | Consecutive restart attempts before cooldown |
| `restartBackoffMs` | `[5000, 30000, 60000]` | Delay per attempt (last value repeats) |
| `cooldownMs` | `600000` | Cooldown after giving up or after an OOM |
| `teardownOnExit` | `true` | Stop the server on dispose if the plugin started it |
| `fallbackModels` | `[]` | Ids to register before discovery succeeds |
| `debug` | `false` | Append lifecycle traces to `%TEMP%\opencode-local-llama.log` |

The kit's `config.json` holds machine-level settings only: `modelsDir`, `toolsDir`, `host`, `port`, `sleepIdleSeconds`, `routerMode`, `modelsMax`, `minBuild`, and `defaults` for sampling.

## Behavior

1. Resolve the kit; scaffold from the bundled framework when `kitPath` is absent.
2. Adopt a healthy server, or spawn `serve-up.ps1` and poll `/health`.
3. Register provider models, seeded from `models.json` and refreshed from `/v1/models`.
4. Start the supervisor loop (15 s tick) when `supervise` is enabled.

Teardown is tied to the process hosting the plugin, not to a TUI window. A resident OpenCode background service keeps the server running (sleeping after the idle period) until that service exits. If the server is killed outside the plugin's control, the next start adopts a healthy server or the kit's `serve-down.ps1` cleans up.

## Security

- The server binds to `127.0.0.1` by default; do not expose it to a network.
- Model weights are third-party artifacts. Review their license and behaviour before use; a model with its refusal layer removed provides no guardrails.
- Keep manual approval enabled in OpenCode when using agentic models.

## License

MIT. See `LICENSE`.
