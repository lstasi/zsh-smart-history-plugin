# Configuration

`zsh-smart-history` is configured entirely through environment variables.

## Minimal Local Setup

```zsh
export ZSH_SMART_HISTORY_MODEL="qwen2.5-coder"
export ZSH_SMART_HISTORY_SUGGESTION_COUNT=5
```

## Remote Ollama Setup

```zsh
export ZSH_SMART_HISTORY_OLLAMA_URL="https://ollama.internal.example.com:11434"
export ZSH_SMART_HISTORY_TIMEOUT=6
```

If `ZSH_SMART_HISTORY_OLLAMA_URL` is unset, the plugin falls back to `OLLAMA_HOST`, then to `http://127.0.0.1:11434`.

## Full Variable Reference

| Variable | Type | Default | Notes |
| --- | --- | --- | --- |
| `ZSH_SMART_HISTORY_ENABLED` | boolean-ish | `1` | Truthy values are `1`, `true`, `yes`, and `on`. |
| `ZSH_SMART_HISTORY_MODEL` | string | `codellama` | Any Ollama model available on the configured host. |
| `ZSH_SMART_HISTORY_SUGGESTION_COUNT` | integer | `3` | The helper always clamps to at least 1 result. |
| `ZSH_SMART_HISTORY_OLLAMA_URL` | string | `http://127.0.0.1:11434` | Accepts `http://`, `https://`, or `host:port`. |
| `ZSH_SMART_HISTORY_TIMEOUT` | float | `4` | Request timeout in seconds. |
| `ZSH_SMART_HISTORY_HISTORY_LIMIT` | integer | `500` | How many recent entries are inspected before compaction. |
| `ZSH_SMART_HISTORY_MAX_COMMAND_LENGTH` | integer | `300` | Commands longer than this may be dropped as noise. |
| `ZSH_SMART_HISTORY_COMPACT_CACHE_MAX_AGE` | float | `3600` | Maximum age in seconds for the cached compacted history snapshot. Use `0` to disable the cache. |
| `ZSH_SMART_HISTORY_PYTHON` | string | `python3` | Use this if Python is not on the default path. |
| `ZSH_SMART_HISTORY_DEBUG_LOG` | string | unset | Append debug logs from the plugin and helper. Set to `1` to use `~/.cache/zsh-smart-history/debug.log`, or provide an explicit path. |
| `ZSH_SMART_HISTORY_KEYBIND` | Zsh bindkey sequence | `^@` | Set to an empty string to disable automatic binding. |

## Recommended Overrides

- Use a larger timeout for a remote Ollama host.
- Use a smaller `ZSH_SMART_HISTORY_HISTORY_LIMIT` on very large history files if you want faster responses.
- Lower `ZSH_SMART_HISTORY_COMPACT_CACHE_MAX_AGE` if your history changes rapidly and you want the compacted snapshot refreshed more aggressively.
- Enable `ZSH_SMART_HISTORY_DEBUG_LOG` while debugging widget bindings or Ollama connectivity, then disable it once you are done.
- Pick an explicit alternate keybinding when `Ctrl-Space` is intercepted by your terminal or desktop environment.
