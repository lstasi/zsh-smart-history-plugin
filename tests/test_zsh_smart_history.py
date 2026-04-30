from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from lib import zsh_smart_history


class ParseHistoryLinesTest(unittest.TestCase):
    def test_parse_extended_history_with_multiline_entries(self) -> None:
        lines = [
            ": 1715200000:0;git status\n",
            ": 1715200001:0;printf 'hello' \\\n",
            "  && echo done\n",
        ]

        parsed = zsh_smart_history.parse_history_lines(lines)

        self.assertEqual(parsed, ["git status", "printf 'hello' \\\n  && echo done"])


class SanitizationTest(unittest.TestCase):
    def test_sanitizes_passwords_tokens_and_url_credentials(self) -> None:
        command = (
            "curl -H 'Authorization: Bearer abc123' https://user:secret@example.com "
            "--password=hunter2 api_key=mykey"
        )

        sanitized = zsh_smart_history.sanitize_command(command)

        self.assertIn("Bearer <redacted>", sanitized)
        self.assertIn("https://user:<redacted>@example.com", sanitized)
        self.assertIn("--password=<redacted>", sanitized)
        self.assertIn("api_key=<redacted>", sanitized)


class NoiseFilterTest(unittest.TestCase):
    def test_filters_large_json_dump(self) -> None:
        noisy_command = "{" + '"k":"' + ("x" * 200) + '"}'

        self.assertTrue(zsh_smart_history.looks_like_noise(noisy_command, 300))


class RankingTest(unittest.TestCase):
    def test_prefix_match_beats_frequency(self) -> None:
        stats = [
            zsh_smart_history.CommandStat("docker compose logs app", count=5, last_seen=5),
            zsh_smart_history.CommandStat("git status", count=10, last_seen=10),
            zsh_smart_history.CommandStat("docker compose up", count=2, last_seen=20),
        ]

        suggestions = zsh_smart_history.fallback_suggestions(stats, "docker co", "/workspace/app", 2)

        self.assertEqual(suggestions[0], "docker compose up")


class SuggestTest(unittest.TestCase):
    def test_normalizes_ollama_url_without_scheme(self) -> None:
        normalized = zsh_smart_history.normalize_ollama_url("ollama.example.internal:11434/")

        self.assertEqual(normalized, "http://ollama.example.internal:11434")

    def test_uses_custom_ollama_url(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            history_path = Path(tmpdir) / "history"
            history_path.write_text(": 1715200000:0;git status\n", encoding="utf-8")

            with patch("lib.zsh_smart_history.call_ollama") as call_ollama:
                call_ollama.return_value = "git status\n"

                suggestions = zsh_smart_history.suggest(
                    history_path=str(history_path),
                    cwd=tmpdir,
                    current_buffer="git",
                    count=3,
                    model="qwen2.5-coder",
                    ollama_url="https://ollama.example.internal:11434",
                    timeout_seconds=1.0,
                    history_limit=100,
                    max_command_length=300,
                )

        self.assertEqual(suggestions[0], "git status")
        call_ollama.assert_called_once()
        self.assertEqual(call_ollama.call_args.args[0], "https://ollama.example.internal:11434")

    def test_falls_back_when_ollama_errors(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            history_path = Path(tmpdir) / "history"
            history_path.write_text(
                "\n".join(
                    [
                        ": 1715200000:0;git status",
                        ": 1715200001:0;git status",
                        ": 1715200002:0;git add .",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            with patch("lib.zsh_smart_history.call_ollama", side_effect=OSError("boom")):
                suggestions = zsh_smart_history.suggest(
                    history_path=str(history_path),
                    cwd=tmpdir,
                    current_buffer="git",
                    count=2,
                    model="codellama",
                    ollama_url="http://127.0.0.1:11434",
                    timeout_seconds=1.0,
                    history_limit=100,
                    max_command_length=300,
                )

        self.assertEqual(suggestions, ["git status", "git add ."])


class CompactCommandTest(unittest.TestCase):
    def test_compact_output_is_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            history_path = Path(tmpdir) / "history"
            history_path.write_text(": 1715200000:0;git status\n", encoding="utf-8")

            output = zsh_smart_history._compact_output(str(history_path), 100, 300)

        parsed = json.loads(output)
        self.assertEqual(parsed[0]["command"], "git status")


if __name__ == "__main__":
    unittest.main()
