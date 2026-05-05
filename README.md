# zsh-smart-history

`zsh-smart-history` is an Oh My Zsh plugin that turns your recent Zsh history into command suggestions powered by Ollama.

It reads your normal `HISTFILE`, removes noise, scrubs common secrets, keeps the most relevant commands, and combines that compacted history with your current working directory and a sanitized version of the text already in your prompt. By default it talks to a local Ollama instance, but you can point it at an external Ollama host with an environment variable.

This project does **not** depend on `per-directory-history`, and it is not derived from that plugin.

## Features

- AI-backed command suggestions from your recent shell history
- Secret scrubbing for common tokens, passwords, bearer headers, AWS env vars, and URL credentials
- Noise filtering for large pastes, dumps, and obviously non-command history entries
- Current-directory context without a custom per-directory history store
- Graceful fallback to history-only ranking when Ollama is unavailable
- Interactive ZLE flow: trigger suggestions, cycle with Up/Down, accept with Tab or Enter, cancel with Esc
- Configurable model, suggestion count, timeout, history depth, keybinding, and Ollama base URL
- Standard-library-only helper script plus unit tests and GitHub Actions workflows
- Cached compaction so large history files do not need a full refresh on every request

## Requirements

- Zsh
- Oh My Zsh
- Python 3.9+
- Ollama reachable from the machine running the shell

## Installation

1. Clone the repository into your Oh My Zsh custom plugins directory.

```bash
git clone https://github.com/lstasi/zsh-smart-history-plugin ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-smart-history
```

2. Add the plugin to your `plugins` list in `~/.zshrc`.

```zsh
plugins=(... zsh-smart-history)
```

3. Add any optional configuration variables before `source $ZSH/oh-my-zsh.sh`.

```zsh
export ZSH_SMART_HISTORY_MODEL="qwen2.5-coder"
export ZSH_SMART_HISTORY_SUGGESTION_COUNT=5
export ZSH_SMART_HISTORY_OLLAMA_URL="http://127.0.0.1:11434"
```

4. Reload your shell.

```bash
source ~/.zshrc
```

## Configuration

All configuration is environment-variable driven.

| Variable | Default | Description |
| --- | --- | --- |
| `ZSH_SMART_HISTORY_ENABLED` | `1` | Set to `0`, `false`, `no`, or `off` to disable the widget without uninstalling. |
| `ZSH_SMART_HISTORY_MODEL` | `codellama` | Ollama model name sent to `/api/generate`. |
| `ZSH_SMART_HISTORY_SUGGESTION_COUNT` | `3` | Maximum number of suggestions returned to the widget. |
| `ZSH_SMART_HISTORY_OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama base URL. If unset, the plugin also honors `OLLAMA_HOST`. |
| `ZSH_SMART_HISTORY_TIMEOUT` | `4` | Request timeout in seconds. |
| `ZSH_SMART_HISTORY_HISTORY_LIMIT` | `500` | Number of most recent history entries inspected before compaction. |
| `ZSH_SMART_HISTORY_MAX_COMMAND_LENGTH` | `300` | Length cutoff used by the noise filter. |
| `ZSH_SMART_HISTORY_COMPACT_CACHE_MAX_AGE` | `3600` | Maximum age in seconds for the cached compacted history snapshot. Set to `0` to rebuild on every request. |
| `ZSH_SMART_HISTORY_PYTHON` | `python3` | Python executable used to run the helper script. |
| `ZSH_SMART_HISTORY_DEBUG_LOG` | unset | When set, append debug logs from the widget and helper. Use `1` to log to `~/.cache/zsh-smart-history/debug.log` or provide an explicit path. |
| `ZSH_SMART_HISTORY_KEYBIND` | `^@` | Key sequence bound to the widget. `^@` is the usual `Ctrl-Space` representation in Zsh. Set it to an empty string to disable automatic binding. |

More examples are in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

### External Ollama

To use a remote Ollama instance, set `ZSH_SMART_HISTORY_OLLAMA_URL` to a reachable HTTP or HTTPS endpoint.

```zsh
export ZSH_SMART_HISTORY_OLLAMA_URL="https://ollama.internal.example.com:11434"
```

If you omit the scheme and set `host:port`, the helper automatically normalizes it to `http://host:port`.

Privacy note: when you point the plugin to a remote Ollama host, the sanitized compacted history summary and sanitized current buffer leave your machine and are sent to that host.

## Usage

1. Press your configured trigger key. The default is `Ctrl-Space`.
2. The helper reuses a recent compacted-history cache when available, otherwise refreshes it from the recent end of `HISTFILE`, then requests suggestions from Ollama.
3. If multiple suggestions are returned, use Up or Down to cycle through them.
4. Press Tab or Enter to keep the currently previewed suggestion in the command line.
5. Press Esc or Ctrl-C to restore the original buffer.

The widget never executes the suggested command automatically.

### Suggested Keybinding Override

Some terminals do not pass `Ctrl-Space` cleanly. If that happens, choose an explicit sequence such as `Ctrl-X Ctrl-H`.

```zsh
export ZSH_SMART_HISTORY_KEYBIND='^X^H'
```

## How It Works

The repository has two main runtime components:

- [zsh-smart-history.plugin.zsh](zsh-smart-history.plugin.zsh) defines the widget, keybinding, selection menu, and user-facing behavior.
- [lib/zsh_smart_history.py](lib/zsh_smart_history.py) reads recent history, caches the compacted summary, sanitizes secrets, ranks fallback suggestions, and queries Ollama.

The helper also exposes a `compact` subcommand for inspecting the sanitized history summary.

```bash
python3 lib/zsh_smart_history.py compact --history-path ~/.zsh_history
```

To inspect widget activity and Ollama calls, enable the optional debug log before `source $ZSH/oh-my-zsh.sh`.

```zsh
export ZSH_SMART_HISTORY_DEBUG_LOG=1
```

That writes logs to `~/.cache/zsh-smart-history/debug.log`. You can also set a custom path instead.

```zsh
export ZSH_SMART_HISTORY_DEBUG_LOG="$HOME/.zsh-smart-history.log"
```

The log records trigger activity, helper execution, cache behavior, Ollama request start or finish, and fallback reasons. It does not write the raw prompt or full history contents.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common setup and runtime issues.

## Development

Run the checks locally with:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
zsh -n zsh-smart-history.plugin.zsh
```

CI runs the same checks on GitHub Actions, and the release workflow packages the repository on version tags.

## Roadmap

Active follow-up work lives in [TODO.md](TODO.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

This project is available under the MIT License. See [LICENSE](LICENSE).
