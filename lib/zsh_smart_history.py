#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib import error, request


DEFAULT_MODEL = "codellama"
DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"
DEFAULT_SUGGESTION_COUNT = 3
DEFAULT_HISTORY_LIMIT = 500
DEFAULT_MAX_COMMAND_LENGTH = 300
DEFAULT_TIMEOUT_SECONDS = 4.0

EXTENDED_HISTORY_PATTERN = re.compile(r"^: \d+:\d+;(.*)$")
NUMBERED_LINE_PATTERN = re.compile(r"^\s*(?:[-*]|\d+[.)])\s*(.+)$")
LONG_BASE64_PATTERN = re.compile(r"[A-Za-z0-9+/=]{120,}")

SENSITIVE_PATTERNS = [
    (
        re.compile(r"(?i)(\b(?:api[_-]?key|token|secret|password|passwd)\b\s*[=:]\s*)(['\"]?)([^\s'\"]+)(\2)"),
        r"\1<redacted>",
    ),
    (
        re.compile(r"(?i)(\bAWS_(?:ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)=)([^\s]+)"),
        r"\1<redacted>",
    ),
    (
        re.compile(r"(?i)(\bAuthorization:\s*Bearer\s+)([^\s]+)"),
        r"\1<redacted>",
    ),
    (
        re.compile(r"(?i)(\b--password(?:=|\s+))(?:[^\s]+)"),
        r"\1<redacted>",
    ),
    (
        re.compile(r"(?i)(\b-p)([^\s]+)"),
        r"\1<redacted>",
    ),
    (
        re.compile(r"(?i)(://[^:\s/]+:)([^@\s]+)(@)"),
        r"\1<redacted>\3",
    ),
    (
        re.compile(
            r"-----BEGIN [A-Z ]+PRIVATE KEY-----.*?-----END [A-Z ]+PRIVATE KEY-----",
            re.DOTALL,
        ),
        "<redacted-private-key>",
    ),
]


@dataclass(frozen=True)
class CommandStat:
    command: str
    count: int
    last_seen: int


def _env_int(name: str, default: int) -> int:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    try:
        parsed = int(value)
    except ValueError:
        return default
    return parsed if parsed > 0 else default


def _env_float(name: str, default: float) -> float:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    try:
        parsed = float(value)
    except ValueError:
        return default
    return parsed if parsed > 0 else default


def normalize_ollama_url(base_url: str) -> str:
    normalized = base_url.strip().rstrip("/")
    if not normalized:
        return DEFAULT_OLLAMA_URL
    if not re.match(r"^https?://", normalized, re.IGNORECASE):
        normalized = f"http://{normalized}"
    return normalized


def parse_history_lines(lines: Iterable[str]) -> list[str]:
    commands: list[str] = []
    current: str | None = None

    for raw_line in lines:
        line = raw_line.rstrip("\n")
        extended_match = EXTENDED_HISTORY_PATTERN.match(line)
        if extended_match:
            if current is not None:
                commands.append(current)
            current = extended_match.group(1)
            continue

        if current is None:
            if line.strip():
                commands.append(line)
            continue

        current = f"{current}\n{line}"

    if current is not None:
        commands.append(current)

    return commands


def collapse_command(command: str) -> str:
    collapsed = re.sub(r"\s*\\\s*\n\s*", " ", command)
    collapsed = re.sub(r"\s+", " ", collapsed)
    return collapsed.strip()


def looks_like_noise(command: str, max_command_length: int) -> bool:
    stripped = command.strip()
    if not stripped:
        return True

    if len(stripped) > max_command_length:
        if "\\\n" not in command and stripped.count(" --") < 2:
            return True

    if stripped.count("\n") >= 8:
        return True

    if LONG_BASE64_PATTERN.search(stripped):
        return True

    if len(stripped) > 120 and stripped[:1] in {"{", "[", "<"}:
        return True

    return False


def sanitize_command(command: str) -> str:
    sanitized = command
    for pattern, replacement in SENSITIVE_PATTERNS:
        sanitized = pattern.sub(replacement, sanitized)
    return sanitized


def sanitize_commands(commands: Iterable[str], max_command_length: int) -> list[str]:
    sanitized_commands: list[str] = []
    for command in commands:
        collapsed = collapse_command(command)
        if looks_like_noise(collapsed, max_command_length):
            continue
        sanitized = sanitize_command(collapsed)
        if sanitized:
            sanitized_commands.append(sanitized)
    return sanitized_commands


def build_command_stats(commands: Iterable[str]) -> list[CommandStat]:
    counts: Counter[str] = Counter()
    last_seen: dict[str, int] = {}

    for index, command in enumerate(commands):
        counts[command] += 1
        last_seen[command] = index

    return [
        CommandStat(command=command, count=count, last_seen=last_seen[command])
        for command, count in counts.items()
    ]


def _tokenize(text: str) -> set[str]:
    return {token.lower() for token in re.findall(r"[A-Za-z0-9._/-]+", text) if token}


def score_command(stat: CommandStat, current_buffer: str, cwd: str, recency_span: int) -> float:
    buffer_text = current_buffer.strip()
    buffer_tokens = _tokenize(buffer_text)
    command_tokens = _tokenize(stat.command)
    cwd_tokens = _tokenize(cwd)

    score = float(stat.count * 5)
    if recency_span > 0:
        score += (stat.last_seen / recency_span) * 30

    if buffer_text:
        if stat.command.startswith(buffer_text):
            score += 100
        elif buffer_text in stat.command:
            score += 40
        score += len(buffer_tokens & command_tokens) * 8

    if cwd_tokens:
        score += len(cwd_tokens & command_tokens) * 3
        cwd_name = Path(cwd).name
        if cwd_name and cwd_name in stat.command:
            score += 6

    if stat.command.startswith("git "):
        score += 3

    return score


def fallback_suggestions(
    stats: Iterable[CommandStat],
    current_buffer: str,
    cwd: str,
    count: int,
) -> list[str]:
    stats_list = list(stats)
    if not stats_list:
        return []

    recency_span = max(stat.last_seen for stat in stats_list) or 1
    ranked = sorted(
        stats_list,
        key=lambda stat: (
            score_command(stat, current_buffer, cwd, recency_span),
            stat.last_seen,
        ),
        reverse=True,
    )

    results: list[str] = []
    normalized_buffer = current_buffer.strip()
    for stat in ranked:
        if normalized_buffer and stat.command == normalized_buffer:
            continue
        if stat.command not in results:
            results.append(stat.command)
        if len(results) >= count:
            break
    return results


def build_prompt(stats: Iterable[CommandStat], current_buffer: str, cwd: str, count: int) -> str:
    summary_lines = [
        "You are completing shell commands for a Zsh user.",
        "Return only shell commands, one per line, no numbering, no explanations.",
        f"Current working directory: {cwd}",
        f"Current partially typed command: {current_buffer or '<empty>'}",
        f"Return at most {count} commands.",
        "History summary (most relevant commands with count and recency):",
    ]

    sorted_stats = sorted(stats, key=lambda stat: (stat.count, stat.last_seen), reverse=True)
    for stat in sorted_stats[:25]:
        summary_lines.append(f"- count={stat.count}; last_seen={stat.last_seen}; command={stat.command}")

    return "\n".join(summary_lines)


def call_ollama(base_url: str, model: str, prompt: str, timeout_seconds: float) -> str:
    normalized_url = normalize_ollama_url(base_url)
    payload = json.dumps(
        {
            "model": model,
            "prompt": prompt,
            "system": "Suggest realistic shell commands. Return commands only.",
            "stream": False,
            "options": {"temperature": 0.2},
        }
    ).encode("utf-8")
    url = f"{normalized_url}/api/generate"
    req = request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with request.urlopen(req, timeout=timeout_seconds) as response:
        body = response.read().decode("utf-8")
    parsed = json.loads(body)
    return str(parsed.get("response", ""))


def parse_ollama_suggestions(text: str, count: int) -> list[str]:
    suggestions: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("```"):
            continue
        numbered = NUMBERED_LINE_PATTERN.match(line)
        if numbered:
            line = numbered.group(1).strip()
        if not line or line.lower().startswith("command"):
            continue
        if re.search(r"\b(?:because|explanation|suggestion)\b", line, re.IGNORECASE):
            continue
        if line not in suggestions:
            suggestions.append(line)
        if len(suggestions) >= count:
            break
    return suggestions


def merge_suggestions(primary: Iterable[str], fallback: Iterable[str], count: int) -> list[str]:
    merged: list[str] = []
    for suggestion in list(primary) + list(fallback):
        cleaned = suggestion.strip()
        if not cleaned or cleaned in merged:
            continue
        merged.append(cleaned)
        if len(merged) >= count:
            break
    return merged


def load_history_file(path: str) -> list[str]:
    history_path = Path(path).expanduser()
    if not history_path.exists():
        return []
    with history_path.open("r", encoding="utf-8", errors="ignore") as history_file:
        return parse_history_lines(history_file)


def suggest(
    history_path: str,
    cwd: str,
    current_buffer: str,
    count: int,
    model: str,
    ollama_url: str,
    timeout_seconds: float,
    history_limit: int,
    max_command_length: int,
) -> list[str]:
    commands = load_history_file(history_path)
    if history_limit > 0:
        commands = commands[-history_limit:]

    sanitized_commands = sanitize_commands(commands, max_command_length)
    stats = build_command_stats(sanitized_commands)
    fallback = fallback_suggestions(stats, current_buffer, cwd, count)

    if not stats:
        return fallback

    prompt = build_prompt(stats, current_buffer, cwd, count)
    try:
        ollama_text = call_ollama(ollama_url, model, prompt, timeout_seconds)
    except (OSError, ValueError, error.HTTPError, error.URLError, TimeoutError):
        return fallback

    ollama_suggestions = parse_ollama_suggestions(ollama_text, count)
    return merge_suggestions(ollama_suggestions, fallback, count)


def _compact_output(history_path: str, history_limit: int, max_command_length: int) -> str:
    commands = load_history_file(history_path)
    if history_limit > 0:
        commands = commands[-history_limit:]
    sanitized_commands = sanitize_commands(commands, max_command_length)
    stats = sorted(
        build_command_stats(sanitized_commands),
        key=lambda stat: (stat.count, stat.last_seen),
        reverse=True,
    )
    return json.dumps(
        [
            {"command": stat.command, "count": stat.count, "last_seen": stat.last_seen}
            for stat in stats
        ],
        indent=2,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="History compaction and suggestion helper for zsh-smart-history.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    suggest_parser = subparsers.add_parser("suggest", help="Generate command suggestions.")
    suggest_parser.add_argument("--history-path", default=os.environ.get("HISTFILE", str(Path.home() / ".zsh_history")))
    suggest_parser.add_argument("--cwd", default=os.getcwd())
    suggest_parser.add_argument("--buffer", default="")
    suggest_parser.add_argument("--count", type=int, default=_env_int("ZSH_SMART_HISTORY_SUGGESTION_COUNT", DEFAULT_SUGGESTION_COUNT))
    suggest_parser.add_argument("--model", default=os.environ.get("ZSH_SMART_HISTORY_MODEL", DEFAULT_MODEL))
    suggest_parser.add_argument(
        "--ollama-url",
        default=os.environ.get("ZSH_SMART_HISTORY_OLLAMA_URL") or os.environ.get("OLLAMA_HOST", DEFAULT_OLLAMA_URL),
    )
    suggest_parser.add_argument("--timeout", type=float, default=_env_float("ZSH_SMART_HISTORY_TIMEOUT", DEFAULT_TIMEOUT_SECONDS))
    suggest_parser.add_argument("--history-limit", type=int, default=_env_int("ZSH_SMART_HISTORY_HISTORY_LIMIT", DEFAULT_HISTORY_LIMIT))
    suggest_parser.add_argument("--max-command-length", type=int, default=_env_int("ZSH_SMART_HISTORY_MAX_COMMAND_LENGTH", DEFAULT_MAX_COMMAND_LENGTH))

    compact_parser = subparsers.add_parser("compact", help="Inspect compacted history.")
    compact_parser.add_argument("--history-path", default=os.environ.get("HISTFILE", str(Path.home() / ".zsh_history")))
    compact_parser.add_argument("--history-limit", type=int, default=_env_int("ZSH_SMART_HISTORY_HISTORY_LIMIT", DEFAULT_HISTORY_LIMIT))
    compact_parser.add_argument("--max-command-length", type=int, default=_env_int("ZSH_SMART_HISTORY_MAX_COMMAND_LENGTH", DEFAULT_MAX_COMMAND_LENGTH))

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "compact":
        print(_compact_output(args.history_path, args.history_limit, args.max_command_length))
        return 0

    suggestions = suggest(
        history_path=args.history_path,
        cwd=args.cwd,
        current_buffer=args.buffer,
        count=max(1, args.count),
        model=args.model,
        ollama_url=args.ollama_url,
        timeout_seconds=args.timeout,
        history_limit=max(1, args.history_limit),
        max_command_length=max(32, args.max_command_length),
    )
    print("\n".join(suggestions))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
