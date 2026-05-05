# Troubleshooting

## No Suggestions Appear

- Verify that `HISTFILE` points to a readable Zsh history file.
- Run `python3 lib/zsh_smart_history.py compact --history-path ~/.zsh_history` to confirm the helper can parse history.
- If you rely on Ollama, confirm the configured model exists on the target host.

## The Widget Says It Is Disabled

- Check `ZSH_SMART_HISTORY_ENABLED` in your shell startup files.
- Valid enable values are `1`, `true`, `yes`, and `on`.

## Ctrl-Space Does Not Trigger the Widget

- Your terminal may not send `^@` for `Ctrl-Space`.
- Set `ZSH_SMART_HISTORY_KEYBIND='^X^H'` or another explicit sequence in `~/.zshrc`.

## Remote Ollama Does Not Respond

- Increase `ZSH_SMART_HISTORY_TIMEOUT`.
- Confirm the URL includes the right port and scheme.
- If the helper falls back to history-only suggestions, the widget still works, but you are no longer getting model-generated results.

## I Want to Inspect What the Helper Is Doing

Use the helper directly:

```bash
python3 lib/zsh_smart_history.py compact --history-path ~/.zsh_history
python3 lib/zsh_smart_history.py suggest --history-path ~/.zsh_history --cwd "$PWD" --buffer "git"
```

If results seem stale, lower `ZSH_SMART_HISTORY_COMPACT_CACHE_MAX_AGE` or set it to `0` to force a rebuild on each request.

## I Want Debug Logs

Enable file-backed debug logging before `source $ZSH/oh-my-zsh.sh`:

```zsh
export ZSH_SMART_HISTORY_DEBUG_LOG=1
```

That writes logs to `~/.cache/zsh-smart-history/debug.log`. You can also provide an explicit path instead of `1`.

The log includes plugin trigger activity, helper invocation, compaction cache behavior, Ollama request start or finish, and fallback reasons. It does not include the raw prompt or full history contents.

Tail the log while testing the widget:

```bash
tail -f ~/.cache/zsh-smart-history/debug.log
```
