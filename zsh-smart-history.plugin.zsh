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
: "${ZSH_SMART_HISTORY_AUTOSUGGEST_ENABLED:=1}"
: "${ZSH_SMART_HISTORY_GUIDANCE_PROMPT:=}"
: "${ZSH_SMART_HISTORY_KEYBIND=^@}"
: "${ZSH_SMART_HISTORY_DEBUG_LOG:=}"

typeset -ga _zsh_smart_history_suggestions=()
typeset -g _zsh_smart_history_original_buffer=""
typeset -g _zsh_smart_history_original_cursor=0
typeset -g _zsh_smart_history_previous_keymap="main"
typeset -g _zsh_smart_history_selected_index=1
typeset -g _zsh_smart_history_selection_active=0
typeset -g _zsh_smart_history_menu_initialized=0
typeset -g _zsh_smart_history_async_fd=""
typeset -g _zsh_smart_history_async_child_pid=""
typeset -g _zsh_smart_history_async_mode=""
typeset -g _zsh_smart_history_async_buffer=""
typeset -g _zsh_smart_history_last_autosuggest_buffer=""
typeset -g _zsh_smart_history_cached_buffer=""
typeset -g _zsh_smart_history_cached_suggestion=""
typeset -g _zsh_smart_history_redraw_hook_registered=0

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

_zsh_smart_history_has_autosuggest() {
  emulate -L zsh
  (( ${+widgets[autosuggest-suggest]} && ${+widgets[autosuggest-fetch]} ))
}

_zsh_smart_history_refresh_autosuggest() {
  emulate -L zsh
  _zsh_smart_history_has_autosuggest || return 0
  zle autosuggest-fetch 2>/dev/null || true
}

_zsh_smart_history_cancel_async_request() {
  emulate -L zsh

  if [[ -n "${_zsh_smart_history_async_fd}" ]] && { true <&$_zsh_smart_history_async_fd } 2>/dev/null; then
    zle -F "${_zsh_smart_history_async_fd}" 2>/dev/null || true
    builtin exec {_zsh_smart_history_async_fd}<&-
  fi

  if [[ -n "${_zsh_smart_history_async_child_pid}" ]]; then
    if [[ -o MONITOR ]]; then
      kill -TERM -${_zsh_smart_history_async_child_pid} 2>/dev/null || true
    else
      kill -TERM ${_zsh_smart_history_async_child_pid} 2>/dev/null || true
    fi
  fi

  _zsh_smart_history_async_fd=""
  _zsh_smart_history_async_child_pid=""
  _zsh_smart_history_async_mode=""
  _zsh_smart_history_async_buffer=""
}

_zsh_smart_history_prepare_helper_command() {
  emulate -L zsh

  reply=()

  if ! _zsh_smart_history_is_truthy "${ZSH_SMART_HISTORY_ENABLED}"; then
    _zsh_smart_history_log "request skip reason=disabled"
    return 1
  fi

  if ! command -v -- "${ZSH_SMART_HISTORY_PYTHON}" >/dev/null 2>&1; then
    _zsh_smart_history_log "request skip reason=missing-python python=${ZSH_SMART_HISTORY_PYTHON}"
    return 1
  fi

  if [[ ! -f "${_ZSH_SMART_HISTORY_HELPER}" ]]; then
    _zsh_smart_history_log "request skip reason=missing-helper helper=${_ZSH_SMART_HISTORY_HELPER}"
    return 1
  fi

  local mode="$1"
  local count="$2"
  local buffer_snapshot="$3"
  local history_path="${HISTFILE:-$HOME/.zsh_history}"

  reply=(
    "${ZSH_SMART_HISTORY_PYTHON}"
    "${_ZSH_SMART_HISTORY_HELPER}"
    suggest
    --history-path "${history_path}"
    --cwd "${PWD}"
    --buffer "${buffer_snapshot}"
    --count "${count}"
    --model "${ZSH_SMART_HISTORY_MODEL}"
    --ollama-url "${ZSH_SMART_HISTORY_OLLAMA_URL}"
    --timeout "${ZSH_SMART_HISTORY_TIMEOUT}"
    --history-limit "${ZSH_SMART_HISTORY_HISTORY_LIMIT}"
    --max-command-length "${ZSH_SMART_HISTORY_MAX_COMMAND_LENGTH}"
  )

  if [[ -n "${ZSH_SMART_HISTORY_GUIDANCE_PROMPT}" ]]; then
    reply+=(--guidance-prompt "${ZSH_SMART_HISTORY_GUIDANCE_PROMPT}")
  fi

  _zsh_smart_history_log \
    "request prepared mode=${mode} history_path=${history_path} model=${ZSH_SMART_HISTORY_MODEL} timeout=${ZSH_SMART_HISTORY_TIMEOUT}"

  return 0
}

_zsh_smart_history_start_async_request() {
  emulate -L zsh
  setopt localoptions no_aliases

  local mode="$1"
  local count="$2"
  local buffer_snapshot="$3"
  local -a command

  _zsh_smart_history_prepare_helper_command "${mode}" "${count}" "${buffer_snapshot}" || {
    if [[ "${mode}" == "menu" ]]; then
      _zsh_smart_history_message "smart-history could not start the helper"
    fi
    return 1
  }
  command=("${reply[@]}")

  _zsh_smart_history_cancel_async_request

  _zsh_smart_history_async_mode="${mode}"
  _zsh_smart_history_async_buffer="${buffer_snapshot}"

  if [[ "${mode}" == "autosuggest" ]]; then
    _zsh_smart_history_last_autosuggest_buffer="${buffer_snapshot}"
  fi

  builtin exec {_zsh_smart_history_async_fd}< <(
    zmodload zsh/system 2>/dev/null || true
    print -r -- "${sysparams[pid]:-}"
    "${command[@]}" 2>/dev/null
    print -r -- "__zsh_smart_history_status=$?"
  )

  IFS= read -r _zsh_smart_history_async_child_pid <&$_zsh_smart_history_async_fd
  zle -F "${_zsh_smart_history_async_fd}" _zsh_smart_history_async_response
  _zsh_smart_history_log \
    "request start mode=${mode} buffer_chars=${#buffer_snapshot} count=${count}"
  return 0
}

_zsh_smart_history_finish_selection() {
  emulate -L zsh
  _zsh_smart_history_selection_active=0
  zle -K "${_zsh_smart_history_previous_keymap:-main}"
  _zsh_smart_history_clear_message
  _zsh_smart_history_refresh_autosuggest
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

_zsh_smart_history_handle_suggestions() {
  emulate -L zsh
  local -a suggestions
  suggestions=("$@")
  (( ${#suggestions} > 0 )) || return 1

  _zsh_smart_history_suggestions=("${suggestions[@]}")
  _zsh_smart_history_selected_index=1

  if (( ${#_zsh_smart_history_suggestions} == 1 )); then
    BUFFER="${_zsh_smart_history_suggestions[1]}"
    CURSOR=${#BUFFER}
    _zsh_smart_history_log "trigger single-suggestion accepted"
    _zsh_smart_history_message "smart-history loaded 1 suggestion"
    _zsh_smart_history_refresh_autosuggest
    zle redisplay
    return 0
  fi

  _zsh_smart_history_init_menu
  _zsh_smart_history_selection_active=1
  _zsh_smart_history_previous_keymap="${KEYMAP:-main}"
  zle -K zsh-smart-history-menu
  _zsh_smart_history_log "trigger menu-open suggestions=${#_zsh_smart_history_suggestions}"
  _zsh_smart_history_show_selection
  return 0
}

_zsh_smart_history_async_response() {
  emulate -L zsh

  local fd="$1"
  local event="$2"
  local mode="${_zsh_smart_history_async_mode}"
  local buffer_snapshot="${_zsh_smart_history_async_buffer}"
  local output=""

  if [[ -z "${event}" || "${event}" == "hup" ]]; then
    IFS='' read -rd '' -u "$fd" output
  fi

  zle -F "$fd" 2>/dev/null || true
  builtin exec {fd}<&-
  _zsh_smart_history_async_fd=""
  _zsh_smart_history_async_child_pid=""
  _zsh_smart_history_async_mode=""
  _zsh_smart_history_async_buffer=""

  local -a suggestions
  suggestions=("${(@f)output}")
  suggestions=("${(@)suggestions:#}")

  local status=0
  if (( ${#suggestions} > 0 )) && [[ "${suggestions[-1]}" == __zsh_smart_history_status=* ]]; then
    status=${suggestions[-1]#*=}
    suggestions=("${suggestions[1,-2]}")
  fi

  _zsh_smart_history_log \
    "request done mode=${mode} status=${status} buffer_chars=${#buffer_snapshot} suggestions=${#suggestions}"

  if [[ -n "${event}" && "${event}" != "hup" ]]; then
    _zsh_smart_history_log "request abort mode=${mode} event=${event}"
    return 0
  fi

  if [[ "${mode}" == "autosuggest" ]]; then
    _zsh_smart_history_cached_buffer="${buffer_snapshot}"
    _zsh_smart_history_cached_suggestion=""
    if (( status == 0 && ${#suggestions} > 0 )); then
      _zsh_smart_history_cached_suggestion="${suggestions[1]}"
    fi

    if [[ "${BUFFER}" == "${buffer_snapshot}" ]] && ! (( _zsh_smart_history_selection_active )); then
      if _zsh_smart_history_has_autosuggest; then
        zle autosuggest-suggest -- "${_zsh_smart_history_cached_suggestion}"
        zle -R
      fi
    else
      _zsh_smart_history_log "request stale mode=autosuggest current_buffer_chars=${#BUFFER}"
    fi
    return 0
  fi

  if [[ "${BUFFER}" != "${buffer_snapshot}" ]] && ! (( _zsh_smart_history_selection_active )); then
    _zsh_smart_history_log "request stale mode=${mode} current_buffer_chars=${#BUFFER}"
    _zsh_smart_history_message "smart-history finished for an older buffer; trigger again"
    return 0
  fi

  if (( status != 0 )); then
    _zsh_smart_history_message "smart-history failed to generate suggestions"
    return 0
  fi

  if (( ${#suggestions} == 0 )); then
    _zsh_smart_history_message "smart-history found no suggestions"
    return 0
  fi

  _zsh_smart_history_handle_suggestions "${suggestions[@]}"
}

_zsh_smart_history_pre_redraw() {
  emulate -L zsh

  _zsh_smart_history_is_truthy "${ZSH_SMART_HISTORY_AUTOSUGGEST_ENABLED}" || return 0
  (( _zsh_smart_history_selection_active )) && return 0
  _zsh_smart_history_has_autosuggest || return 0

  if [[ -z "${BUFFER}" ]]; then
    _zsh_smart_history_cached_buffer=""
    _zsh_smart_history_cached_suggestion=""
    _zsh_smart_history_last_autosuggest_buffer=""
    return 0
  fi

  if [[ -n "${_zsh_smart_history_cached_buffer}" && "${_zsh_smart_history_cached_buffer}" == "${BUFFER}" ]]; then
    if [[ -n "${_zsh_smart_history_cached_suggestion}" ]]; then
      zle autosuggest-suggest -- "${_zsh_smart_history_cached_suggestion}"
    fi
    return 0
  fi

  [[ -n "${POSTDISPLAY}" ]] || return 0

  if [[ "${_zsh_smart_history_async_mode}" == "autosuggest" && "${_zsh_smart_history_async_buffer}" == "${BUFFER}" ]]; then
    return 0
  fi

  if [[ "${_zsh_smart_history_last_autosuggest_buffer}" == "${BUFFER}" ]]; then
    return 0
  fi

  _zsh_smart_history_start_async_request autosuggest 1 "${BUFFER}" || return 0
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
  _zsh_smart_history_original_buffer="${BUFFER}"
  _zsh_smart_history_original_cursor=${CURSOR}

  if _zsh_smart_history_has_autosuggest; then
    zle autosuggest-clear 2>/dev/null || true
  fi

  _zsh_smart_history_message "smart-history: generating suggestions..."
  zle -I
  _zsh_smart_history_start_async_request menu "${ZSH_SMART_HISTORY_SUGGESTION_COUNT}" "${BUFFER}" || return 0
}

_zsh_smart_history_bind_widgets() {
  emulate -L zsh
  zle -N zsh-smart-history-trigger _zsh_smart_history_trigger
  zle -N zsh-smart-history-next _zsh_smart_history_next
  zle -N zsh-smart-history-prev _zsh_smart_history_prev
  zle -N zsh-smart-history-commit _zsh_smart_history_commit
  zle -N zsh-smart-history-cancel _zsh_smart_history_cancel
  zle -N zsh-smart-history-pre-redraw _zsh_smart_history_pre_redraw
}

_zsh_smart_history_register_hooks() {
  emulate -L zsh
  (( _zsh_smart_history_redraw_hook_registered )) && return 0

  autoload -Uz add-zle-hook-widget 2>/dev/null || true
  if (( ${+functions[add-zle-hook-widget]} )); then
    add-zle-hook-widget line-pre-redraw zsh-smart-history-pre-redraw 2>/dev/null || true
    _zsh_smart_history_redraw_hook_registered=1
    _zsh_smart_history_log "hook registered name=line-pre-redraw"
    return 0
  fi

  if (( ! ${+widgets[zle-line-pre-redraw]} )); then
    zle -N zle-line-pre-redraw _zsh_smart_history_pre_redraw
    _zsh_smart_history_redraw_hook_registered=1
    _zsh_smart_history_log "hook registered name=zle-line-pre-redraw"
    return 0
  fi

  _zsh_smart_history_log "hook skip reason=missing-line-pre-redraw-support"
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
  _zsh_smart_history_register_hooks
  _zsh_smart_history_log "plugin loaded interactive=1"
fi
