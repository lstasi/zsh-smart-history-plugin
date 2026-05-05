# TODO

The initial implementation is now in the repository. This backlog tracks follow-up work rather than the original scaffold plan.

## Completed in the Current Implementation

- [x] History parsing for standard and extended Zsh history files
- [x] Noise filtering and secret scrubbing before model requests
- [x] Current-directory-aware prompt generation without `per-directory-history`
- [x] External Ollama configuration via `ZSH_SMART_HISTORY_OLLAMA_URL` and `OLLAMA_HOST`
- [x] Fallback ranking when Ollama is unavailable
- [x] Interactive ZLE accept/cancel flow
- [x] Unit tests for helper logic
- [x] GitHub Actions CI and release workflows

## Next Enhancements

- [ ] Add more shell-aware validation for suggested commands
- [ ] Add integration tests that exercise widget behavior in an interactive shell session
- [ ] Add a screenshot or asciinema demo to the README
- [ ] Publish the first tagged release

## Longer-Term Ideas

- [ ] Support alternative backends behind the same helper interface
- [ ] Learn from accepted suggestions locally without storing raw history snapshots
- [ ] Add an opt-in Langfuse or OpenTelemetry exporter for sanitized request traces
