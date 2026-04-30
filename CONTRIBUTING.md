# Contributing

## Local Checks

Run the same commands used by CI before opening a pull request.

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
zsh -n zsh-smart-history.plugin.zsh
```

## Development Notes

- Keep the helper script standard-library-only unless there is a strong reason to add a dependency.
- Preserve the plugin's privacy model: sanitize and compact history before any network request.
- Keep README and configuration docs aligned with the actual environment variables supported by the code.
