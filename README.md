# zsh-smart-history

An Oh My Zsh plugin that supercharges your terminal workflow using local AI (Ollama).

`zsh-smart-history` doesn't just grep your past commands; it intelligently compacts, sanitizes, and analyzes your history to predict exactly what you want to type next. By processing data locally, your history remains private, fast, and highly relevant to the specific directory you are working in.

## ✨ Features

*   🧠 **AI-Powered Suggestions:** Calls your local Ollama instance with your recent context to generate accurate command suggestions.
*   🛡️ **Privacy-First Compaction:** Never sends your raw history file to the AI. A local "compactor" pre-processes the data first.
*   🔒 **Auto-Sanitization:** Automatically strips sensitive data (passwords, API keys, tokens) before the AI sees your history.
*   🧹 **Noise Reduction:** Detects and scrubs accidental large text or code pastes that clutter standard history files.
*   📈 **Smart Sorting:** Removes duplicate commands and weights history based on usage frequency.
*   📂 **Directory Aware:** Suggests commands relevant to your current project folder. Works standalone or in combination with the `per-directory-history` plugin.
*   ⌨️ **Interactive UI:** Navigate through AI suggestions seamlessly using your `Arrow` keys and `Tab` to complete.
*   ⚙️ **Highly Configurable:** Easily define how many suggestions you want returned and which Ollama model to use.

## 🚀 Prerequisites

*   [Oh My Zsh](https://ohmyz.sh/)
*   [Ollama](https://ollama.com/) running locally (we recommend a fast code model like `codellama` or `deepseek-coder`).

## 📦 Installation

1. Clone this repository into your Oh My Zsh custom plugins directory:

```bash
git clone https://github.com/lstasi/zsh-smart-history-plugin ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-smart-history
```

2. Add the plugin to your `~/.zshrc` file:

```zsh
plugins=(... zsh-smart-history)
```

3. Restart your shell or reload the configuration:

```bash
source ~/.zshrc
```

## 🛠️ Configuration

You can customize the plugin by adding the following variables to your `~/.zshrc` before sourcing Oh My Zsh:

```zsh
# Set the Ollama model you want to use (default: codellama)
ZSH_SMART_HISTORY_MODEL="codellama"

# Set the number of suggestions to return (default: 3)
ZSH_SMART_HISTORY_SUGGESTION_COUNT=5

# Enable integration with per-directory-history plugin (default: true)
ZSH_SMART_HISTORY_FOLDER_AWARE=true
```

## 🎯 Usage

Once installed, the plugin will automatically enhance your command-line experience:

*   Press the configured keybinding (default: `Ctrl+Space`) to trigger AI-powered suggestions
*   Use `Arrow` keys to navigate through suggestions
*   Press `Tab` to preview a suggestion
*   Press `Enter` to populate your command buffer (without executing immediately)

## 🏗️ Architecture

The plugin consists of three main components:

### 1. History Compactor
A local data preparation layer that:
- Reads from global or per-directory history files
- Removes duplicate commands
- Sorts commands by usage frequency
- Filters out noise (large pastes, non-commands)
- Sanitizes sensitive data (API keys, passwords, tokens)

### 2. Ollama Integration
An AI layer that:
- Sends compacted history to your local Ollama instance
- Uses a specialized system prompt for command prediction
- Returns configurable number of suggestions
- Maintains privacy by keeping all processing local

### 3. Zsh Line Editor (ZLE) UI
An interactive interface that:
- Binds to keyboard shortcuts
- Displays suggestions in an intuitive menu
- Allows navigation with arrow keys and tab
- Populates the command buffer without auto-execution

## 🔒 Privacy & Security

All processing happens **100% locally** on your machine:
- Your command history never leaves your computer
- Ollama runs locally without external API calls
- Sensitive data is automatically scrubbed before AI processing
- No telemetry, no tracking, no cloud services

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request. See [TODO.md](TODO.md) for the development roadmap.

## 📄 License

This project is open source and available under the MIT License.

## 🙏 Acknowledgments

- Inspired by [per-directory-history](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/per-directory-history)
- Powered by [Ollama](https://ollama.com/)
- Built for [Oh My Zsh](https://ohmyz.sh/)
