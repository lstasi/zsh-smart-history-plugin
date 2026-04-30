# 📝 Development TODO List

This document provides an actionable roadmap to build out the `zsh-smart-history` plugin, broken down by logical components.

## Phase 1: The History Compactor (Data Preparation)

### Core History Reading
- [ ] Create a script (shell, Python, or Go) to read the active Zsh history
- [ ] Implement logic to detect if `per-directory-history` is active
- [ ] If per-directory-history is detected, read from the local directory's history file instead of the global one
- [ ] Add fallback to global history if per-directory-history is not available

### Deduplication & Sorting
- [ ] Write a function to parse the history file format
- [ ] Implement command deduplication logic
- [ ] Track execution count/frequency for each unique command
- [ ] Sort commands by execution count (most frequent first)
- [ ] Handle edge cases (multiline commands, special characters, etc.)

### Noise Reduction
- [ ] Implement a length-based filter to drop history entries exceeding a threshold (e.g., > 300 chars)
- [ ] Detect and filter accidental multi-line pastes
- [ ] Identify and remove non-command entries (e.g., large JSON/XML dumps)
- [ ] Add configurable threshold for noise detection
- [ ] Preserve legitimate long commands (e.g., with proper line continuations)

### Sanitization
- [ ] Write regex patterns to identify common secret patterns:
  - [ ] AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
  - [ ] API keys and tokens (generic patterns like `api_key=`, `token=`)
  - [ ] Bearer tokens in curl commands
  - [ ] Password flags (`-p password`, `--password=`, etc.)
  - [ ] SSH private keys or certificate content
  - [ ] Database connection strings with passwords
- [ ] Implement scrubbing logic to replace detected secrets with placeholders
- [ ] Add configuration option to customize sanitization rules
- [ ] Log sanitization actions (without logging the actual secrets)

## Phase 2: Ollama Integration (AI Layer)

### System Prompt Design
- [ ] Draft the AI system prompt for command prediction
- [ ] Example: *"You are a Zsh terminal assistant. Based on this compacted frequency map of past commands: [DATA], suggest the next [COUNT] most likely commands the user will run. Return ONLY the commands."*
- [ ] Test and refine prompt for optimal results
- [ ] Add context about current directory and environment
- [ ] Include instructions to avoid hallucinating non-existent commands

### API Integration
- [ ] Implement a function to make curl requests to local Ollama API
- [ ] Target endpoint: `http://localhost:11434/api/generate`
- [ ] Handle JSON request/response format
- [ ] Implement timeout handling for slow responses
- [ ] Add error handling for connection failures

### Configuration
- [ ] Wire up `ZSH_SMART_HISTORY_MODEL` variable to API calls
- [ ] Wire up `ZSH_SMART_HISTORY_SUGGESTION_COUNT` to control response size
- [ ] Set sensible defaults (model: `codellama`, count: 3)
- [ ] Add validation for configuration values
- [ ] Document supported Ollama models

### Response Processing
- [ ] Parse Ollama API response
- [ ] Extract command suggestions from AI output
- [ ] Handle malformed or unexpected responses
- [ ] Validate that returned suggestions are reasonable commands
- [ ] Filter out any remaining unsafe or inappropriate suggestions

## Phase 3: Zsh Line Editor (ZLE) UI

### Widget Creation
- [ ] Create a Zsh widget function that triggers the Compactor → Ollama pipeline
- [ ] Implement async execution to avoid blocking the terminal
- [ ] Add loading state management

### Keybinding
- [ ] Bind a shortcut key to trigger the widget (suggest `Ctrl+Space`)
- [ ] Consider alternative binding (intercepting `Ctrl+R` for familiar UX)
- [ ] Make keybinding configurable
- [ ] Document keybinding in README

### Interactive Menu
- [ ] Implement an interactive menu for displaying suggestions
- [ ] Consider leveraging built-in Zsh `zstyle` completion menus
- [ ] Alternative: Integrate with `fzf` for enhanced navigation
- [ ] Implement arrow key navigation (up/down through suggestions)
- [ ] Implement Tab key behavior for selection
- [ ] Add visual indicators for selected item

### Buffer Population
- [ ] Ensure hitting Enter on a selection populates the prompt buffer
- [ ] Use `BUFFER=$selected_command` to populate command line
- [ ] Do NOT auto-execute the command (give user a chance to review/edit)
- [ ] Preserve cursor position appropriately
- [ ] Allow ESC or Ctrl+C to cancel without changing buffer

## Phase 4: Polish & Release

### Error Handling & Fallbacks
- [ ] Add fallback logic if Ollama is not running
- [ ] Display helpful error message when Ollama is unavailable
- [ ] Gracefully degrade if history compaction fails
- [ ] Handle empty history gracefully
- [ ] Add retry logic for transient failures

### User Experience
- [ ] Add a loading indicator during AI generation (e.g., spinner or message)
- [ ] Optimize for fast response times (< 2 seconds)
- [ ] Add configuration to disable plugin without uninstalling
- [ ] Implement debug/verbose mode for troubleshooting

### Documentation
- [ ] Finalize installation instructions in README
- [ ] Add troubleshooting section
- [ ] Create examples/screenshots of the plugin in action
- [ ] Document all configuration options
- [ ] Add FAQ section
- [ ] Write contributor guidelines

### Testing
- [ ] Write unit tests for history compactor
- [ ] Write unit tests for sanitization logic
- [ ] Test with various Ollama models
- [ ] Test integration with per-directory-history plugin
- [ ] Test error cases and edge conditions
- [ ] Performance testing with large history files

### Release Preparation
- [ ] Add LICENSE file (MIT suggested)
- [ ] Create CHANGELOG.md
- [ ] Version the plugin (semantic versioning)
- [ ] Create GitHub release with binaries/assets if needed
- [ ] Announce in Oh My Zsh community
- [ ] Submit to awesome-zsh-plugins list

## Future Enhancements (Post v1.0)

- [ ] Support for other AI backends (OpenAI, Anthropic with API keys)
- [ ] Learn from user's selection patterns to improve suggestions
- [ ] Export/import sanitized history for sharing configurations
- [ ] Integration with other shell environments (bash, fish)
- [ ] Web UI for configuration and history visualization
- [ ] Plugin marketplace for custom sanitization rules
- [ ] Collaborative learning (optional, opt-in, privacy-preserving)

---

## Development Notes

### Recommended Tech Stack
- **Core Plugin:** Zsh scripting
- **Compactor:** Shell script or Python (for regex flexibility)
- **Tests:** zunit or shunit2 for shell testing
- **CI/CD:** GitHub Actions for automated testing

### Performance Considerations
- Keep compaction fast (< 500ms for typical history)
- Cache compacted history between invocations
- Invalidate cache on new commands
- Use streaming responses from Ollama if available

### Security Considerations
- Never log raw history to disk
- Audit sanitization rules regularly
- Provide option for users to review what's sent to AI
- Consider adding a "dry-run" mode to preview compaction
