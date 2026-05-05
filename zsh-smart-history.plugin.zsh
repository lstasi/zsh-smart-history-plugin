0="${(%):-%N}"

typeset -gr ZSH_SMART_HISTORY_PLUGIN_DIR="${0:A:h}"
typeset -gr _ZSH_SMART_HISTORY_HELPER="${ZSH_SMART_HISTORY_PLUGIN_DIR}/lib/zsh_smart_history.py"

: "${ZSH_SMART_HISTORY_ENABLED:=1}"
: "${ZSH_SMART_HISTORY_MODEL:=codellama}"
: "${ZSH_SMART_HISTORY_SUGGESTION_COUNT:=3}"
: "${ZSH_SMART_HISTORY_OLLAMA_URL:=${OLLAMA_HOST:-http://127.0.0.1:11434}}"
: "${ZSH_SMART_HISTORY_TIMEOUT:=4}"
: "${ZSH_SMART_HISTORY_HISTORY_LIMIT:=500}"
: "${ZSH_SMART_HISTORY_MAX_COMMAND_LENGTH:=300}"
: "${ZSH_SMART_HISTORY_PYTHON:=python3}"
: "${ZSH_SMART_HISTORY_KEYBIND=^@}"
: "${ZSH_SMART_HISTORY_DEBUG_LOG:=}"

typeset -ga _zsh_smart_history_suggestions=()
typeset -g _zsh_smart_history_original_buffer=""
typeset -g _zsh_smart_history_original_cursor=0
typeset -g _zsh_smart_history_previous_keymap="main"
typeset -g _zsh_smart_history_selected_index=1
typeset -g _zsh_smart_history_selection_active=0
typeset -g _zsh_smart_history_menu_initialized=0

_zsh_smart_history_is_truthy() {
  emulate -L zsh
  case "${1:l}" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_zsh_smart_history_message() {
  emulate -L zsh
  zle -M "$1"
}

_zsh_smart_history_debug_log_path() {
  emulate -L zsh

  local configured="${ZSH_SMART_HISTORY_DEBUG_LOG}"
  [[ -z "${configured}" ]] && return 1

  case "${configured:l}" in
    1|true|yes|on)
      local cache_base="${XDG_CACHE_HOME:-$HOME/.cache}"
      print -r -- "${cache_base:A}/zsh-smart-history/debug.log"
      return 0
      ;;
  esac

  local expanded="${~configured}"
  print -r -- "${expanded:A}"
}

_zsh_smart_history_log() {
  emulate -L zsh
  setopt localoptions no_aliases

  local log_path
  log_path="$(_zsh_smart_history_debug_log_path)" || return 0

  mkdir -p -- "${log_path:h}" 2>/dev/null || return 0

  local timestamp="unknown-time"
  if command -v -- date >/dev/null 2>&1; then
    timestamp="$(command date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)"
    [[ -z "${timestamp}" ]] && timestamp="unknown-time"
  fi

  print -r -- "${timestamp} [plugin] pid=$$ $*" >> "${log_path}" 2>/dev/null || true
}

_zsh_smart_history_clear_message() {
  emulate -L zsh
  zle -M ""
}

_zsh_smart_history_finish_selection() {
  emulate -L zsh
  _zsh_smart_history_selection_active=0
  zle -K "${_zsh_smart_history_previous_keymap:-main}"
  _zsh_smart_history_clear_message
  zle redisplay
}

_zsh_smart_history_show_selection() {
  emulate -L zsh
  local total=${#_zsh_smart_history_suggestions}
  (( total == 0 )) && return 1

  BUFFER="${_zsh_smart_history_suggestions[_zsh_smart_history_selected_index]}"
  CURSOR=${#BUFFER}
  _zsh_smart_history_message "smart-history ${_zsh_smart_history_selected_index}/${total}: Up/Down cycle, Tab or Enter accept, Esc cancels"
  zle redisplay
}

_zsh_smart_history_next() {
  emulate -L zsh
  (( _zsh_smart_history_selection_active )) || return 0

  local total=${#_zsh_smart_history_suggestions}
  (( total == 0 )) && return 0
  _zsh_smart_history_selected_index=$(( (_zsh_smart_history_selected_index % total) + 1 ))
  _zsh_smart_history_show_selection
}

_zsh_smart_history_prev() {
  emulate -L zsh
  (( _zsh_smart_history_selection_active )) || return 0

  local total=${#_zsh_smart_history_suggestions}
  (( total == 0 )) && return 0
  _zsh_smart_history_selected_index=$(( _zsh_smart_history_selected_index - 1 ))
  if (( _zsh_smart_history_selected_index < 1 )); then
    _zsh_smart_history_selected_index=${total}
  fi
  _zsh_smart_history_show_selection
}

_zsh_smart_history_commit() {
  emulate -L zsh
  (( _zsh_smart_history_selection_active )) || return 0
  _zsh_smart_history_finish_selection
}

_zsh_smart_history_cancel() {
  emulate -L zsh
  (( _zsh_smart_history_selection_active )) || return 0

  BUFFER="${_zsh_smart_history_original_buffer}"
  CURSOR=${_zsh_smart_history_original_cursor}
  _zsh_smart_history_finish_selection
}

_zsh_smart_history_fetch_suggestions() {
  emulate -L zsh
  setopt localoptions pipefail no_aliases

  reply=()
  _zsh_smart_history_log "fetch start cwd=${PWD} buffer_chars=${#BUFFER}"

  if ! _zsh_smart_history_is_truthy "${ZSH_SMART_HISTORY_ENABLED}"; then
    _zsh_smart_history_log "fetch abort reason=disabled"
    _zsh_smart_history_message "smart-history is disabled"
    return 1
  fi

  if ! command -v -- "${ZSH_SMART_HISTORY_PYTHON}" >/dev/null 2>&1; then
    _zsh_smart_history_log "fetch abort reason=missing-python python=${ZSH_SMART_HISTORY_PYTHON}"
    _zsh_smart_history_message "smart-history could not find ${ZSH_SMART_HISTORY_PYTHON}"
    return 1
  fi

  if [[ ! -f "${_ZSH_SMART_HISTORY_HELPER}" ]]; then
    _zsh_smart_history_log "fetch abort reason=missing-helper helper=${_ZSH_SMART_HISTORY_HELPER}"
    _zsh_smart_history_message "smart-history helper script is missing"
    return 1
  fi

  local history_path="${HISTFILE:-$HOME/.zsh_history}"
  local -a command
  command=(
    "${ZSH_SMART_HISTORY_PYTHON}"
    "${_ZSH_SMART_HISTORY_HELPER}"
    suggest
    --history-path "${history_path}"
    --cwd "${PWD}"
    --buffer "${BUFFER}"
    --count "${ZSH_SMART_HISTORY_SUGGESTION_COUNT}"
    --model "${ZSH_SMART_HISTORY_MODEL}"
    --ollama-url "${ZSH_SMART_HISTORY_OLLAMA_URL}"
    --timeout "${ZSH_SMART_HISTORY_TIMEOUT}"
    --history-limit "${ZSH_SMART_HISTORY_HISTORY_LIMIT}"
    --max-command-length "${ZSH_SMART_HISTORY_MAX_COMMAND_LENGTH}"
  )

  _zsh_smart_history_log "helper invoke python=${ZSH_SMART_HISTORY_PYTHON} history_path=${history_path} model=${ZSH_SMART_HISTORY_MODEL} timeout=${ZSH_SMART_HISTORY_TIMEOUT}"

  _zsh_smart_history_message "smart-history: generating suggestions..."
  zle -I

  local output
  local status
  output="$("${command[@]}" 2>/dev/null)"
  status=$?
  _zsh_smart_history_log "helper exit status=${status} output_chars=${#output}"

  if (( status != 0 )); then
    _zsh_smart_history_log "fetch abort reason=helper-failed status=${status}"
    _zsh_smart_history_message "smart-history failed to generate suggestions"
    return 1
  fi

  reply=("${(@f)output}")
  reply=("${(@)reply:#}")

  if (( ${#reply} == 0 )); then
    _zsh_smart_history_log "fetch abort reason=no-suggestions"
    _zsh_smart_history_message "smart-history found no suggestions"
    return 1
  fi

  _zsh_smart_history_log "fetch success suggestions=${#reply}"

  return 0
}

_zsh_smart_history_init_menu() {
  emulate -L zsh
  (( _zsh_smart_history_menu_initialized )) && return 0

  bindkey -N zsh-smart-history-menu emacs
  bindkey -M zsh-smart-history-menu '^[[A' zsh-smart-history-prev
  bindkey -M zsh-smart-history-menu '^[[B' zsh-smart-history-next
  bindkey -M zsh-smart-history-menu '^P' zsh-smart-history-prev
  bindkey -M zsh-smart-history-menu '^N' zsh-smart-history-next
  bindkey -M zsh-smart-history-menu '^I' zsh-smart-history-commit
  bindkey -M zsh-smart-history-menu '^M' zsh-smart-history-commit
  bindkey -M zsh-smart-history-menu '^[' zsh-smart-history-cancel
  bindkey -M zsh-smart-history-menu '^C' zsh-smart-history-cancel

  _zsh_smart_history_menu_initialized=1
}

_zsh_smart_history_trigger() {
  emulate -L zsh
  setopt localoptions no_aliases

  _zsh_smart_history_log "trigger invoked keymap=${KEYMAP:-main} buffer_chars=${#BUFFER}"

  local -a suggestions
  _zsh_smart_history_fetch_suggestions || return 0
  suggestions=("${reply[@]}")

  _zsh_smart_history_suggestions=("${suggestions[@]}")
  _zsh_smart_history_selected_index=1
  _zsh_smart_history_original_buffer="${BUFFER}"
  _zsh_smart_history_original_cursor=${CURSOR}

  if (( ${#_zsh_smart_history_suggestions} == 1 )); then
    BUFFER="${_zsh_smart_history_suggestions[1]}"
    CURSOR=${#BUFFER}
    _zsh_smart_history_log "trigger single-suggestion accepted"
    _zsh_smart_history_message "smart-history loaded 1 suggestion"
    zle redisplay
    return 0
  fi

  _zsh_smart_history_init_menu
  _zsh_smart_history_selection_active=1
  _zsh_smart_history_previous_keymap="${KEYMAP:-main}"
  zle -K zsh-smart-history-menu
  _zsh_smart_history_log "trigger menu-open suggestions=${#_zsh_smart_history_suggestions}"
  _zsh_smart_history_show_selection
}

_zsh_smart_history_bind_widgets() {
  emulate -L zsh
  zle -N zsh-smart-history-trigger _zsh_smart_history_trigger
  zle -N zsh-smart-history-next _zsh_smart_history_next
  zle -N zsh-smart-history-prev _zsh_smart_history_prev
  zle -N zsh-smart-history-commit _zsh_smart_history_commit
  zle -N zsh-smart-history-cancel _zsh_smart_history_cancel
}

_zsh_smart_history_bind_key() {
  emulate -L zsh
  if [[ -z "${ZSH_SMART_HISTORY_KEYBIND}" ]]; then
    _zsh_smart_history_log "bind skip reason=empty-keybind"
    return 0
  fi

  bindkey -M emacs "${ZSH_SMART_HISTORY_KEYBIND}" zsh-smart-history-trigger
  bindkey -M viins "${ZSH_SMART_HISTORY_KEYBIND}" zsh-smart-history-trigger 2>/dev/null || true
  _zsh_smart_history_log "bind success keybind=${ZSH_SMART_HISTORY_KEYBIND}"
}

if [[ -o interactive ]]; then
  _zsh_smart_history_bind_widgets
  _zsh_smart_history_bind_key
  _zsh_smart_history_log "plugin loaded interactive=1"
fi
