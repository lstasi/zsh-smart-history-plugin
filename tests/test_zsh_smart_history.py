from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

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

    def test_sanitizes_mysql_short_password_flag(self) -> None:
        sanitized = zsh_smart_history.sanitize_command("mysql -psecret db")

        self.assertEqual(sanitized, "mysql -p<redacted> db")


class NoiseFilterTest(unittest.TestCase):
    def test_filters_large_json_dump(self) -> None:
        noisy_command = "{" + '"k":"' + ("x" * 200) + '"}'

        self.assertTrue(zsh_smart_history.looks_like_noise(noisy_command, 300))

    def test_filters_large_multiline_paste(self) -> None:
        noisy_command = "\n".join(f"line {index}" for index in range(9))

        self.assertEqual(zsh_smart_history.sanitize_commands([noisy_command], 300), [])

    def test_keeps_line_continued_shell_command(self) -> None:
        command = "printf 'hello' \\\n  && echo done"

        self.assertEqual(
            zsh_smart_history.sanitize_commands([command], 300),
            ["printf 'hello' && echo done"],
        )


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
                    compact_cache_max_age=3600,
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
                    compact_cache_max_age=3600,
                )

        self.assertEqual(suggestions, ["git add .", "git status"])

    def test_sanitizes_current_buffer_before_model_request(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            history_path = Path(tmpdir) / "history"
            history_path.write_text(": 1715200000:0;git status\n", encoding="utf-8")

            with patch("lib.zsh_smart_history.call_ollama") as call_ollama:
                call_ollama.return_value = ""

                zsh_smart_history.suggest(
                    history_path=str(history_path),
                    cwd=tmpdir,
                    current_buffer='curl -H "Authorization: Bearer abc123"',
                    count=3,
                    model="codellama",
                    ollama_url="http://127.0.0.1:11434",
                    timeout_seconds=1.0,
                    history_limit=100,
                    max_command_length=300,
                    compact_cache_max_age=3600,
                )

        prompt = call_ollama.call_args.args[2]
        self.assertIn("Authorization: Bearer <redacted>", prompt)
        self.assertNotIn("abc123", prompt)


class DebugLogTest(unittest.TestCase):
    def test_call_ollama_writes_request_lifecycle_log(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "debug.log"
            response = MagicMock()
            response.__enter__.return_value = response
            response.read.return_value = b'{"response":"git status"}'
            response.status = 200

            with patch.dict(os.environ, {"ZSH_SMART_HISTORY_DEBUG_LOG": str(log_path)}, clear=False):
                with patch("lib.zsh_smart_history.request.urlopen", return_value=response):
                    result = zsh_smart_history.call_ollama("127.0.0.1:11434", "codellama", "prompt", 1.0)

        self.assertEqual(result, "git status")
        log_contents = log_path.read_text(encoding="utf-8")
        self.assertIn("ollama request start", log_contents)
        self.assertIn("url=http://127.0.0.1:11434", log_contents)
        self.assertIn("ollama request done", log_contents)
        self.assertIn("response_chars=10", log_contents)

    def test_suggest_logs_fallback_after_ollama_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            history_path = Path(tmpdir) / "history"
            log_path = Path(tmpdir) / "debug.log"
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

            with patch.dict(
                os.environ,
                {
                    "ZSH_SMART_HISTORY_DEBUG_LOG": str(log_path),
                    "XDG_CACHE_HOME": tmpdir,
                },
                clear=False,
            ):
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
                        compact_cache_max_age=3600,
                    )

        self.assertEqual(suggestions, ["git add .", "git status"])
        log_contents = log_path.read_text(encoding="utf-8")
        self.assertIn("suggest start", log_contents)
        self.assertIn("compaction cache=write", log_contents)
        self.assertIn("suggest return reason=ollama-fallback", log_contents)


class CompactionCacheTest(unittest.TestCase):
    def test_load_recent_history_reads_only_tail_entries(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            history_path = Path(tmpdir) / "history"
            history_path.write_text(
                "\n".join(
                    [
                        ": 1715200000:0;git status",
                        ": 1715200001:0;git add .",
                        ": 1715200002:0;git commit -m test",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            commands = zsh_smart_history.load_recent_history(str(history_path), 2)

        self.assertEqual(commands, ["git add .", "git commit -m test"])

    def test_compaction_cache_reuses_fresh_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            history_path = Path(tmpdir) / "history"
            history_path.write_text(": 1715200000:0;git status\n", encoding="utf-8")

            with patch.dict(os.environ, {"XDG_CACHE_HOME": tmpdir}, clear=False):
                first = zsh_smart_history.load_compacted_history(str(history_path), 100, 300, 3600)

                with patch("lib.zsh_smart_history.load_recent_history", side_effect=AssertionError("cache miss")):
                    second = zsh_smart_history.load_compacted_history(str(history_path), 100, 300, 3600)

        self.assertEqual(first, ["git status"])
        self.assertEqual(second, ["git status"])

    def test_compaction_cache_refreshes_after_history_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            history_path = Path(tmpdir) / "history"
            history_path.write_text(": 1715200000:0;git status\n", encoding="utf-8")

            with patch.dict(os.environ, {"XDG_CACHE_HOME": tmpdir}, clear=False):
                first = zsh_smart_history.load_compacted_history(str(history_path), 100, 300, 3600)

                history_path.write_text(
                    ": 1715200000:0;git status\n: 1715200001:0;git add .\n",
                    encoding="utf-8",
                )

                second = zsh_smart_history.load_compacted_history(str(history_path), 100, 300, 3600)

        self.assertEqual(first, ["git status"])
        self.assertEqual(second, ["git status", "git add ."])

    def test_zero_cache_age_forces_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            history_path = Path(tmpdir) / "history"
            history_path.write_text(": 1715200000:0;git status\n", encoding="utf-8")

            with patch.dict(os.environ, {"XDG_CACHE_HOME": tmpdir}, clear=False):
                zsh_smart_history.load_compacted_history(str(history_path), 100, 300, 3600)

                with patch("lib.zsh_smart_history.load_recent_history", return_value=["git add ."]) as load_recent_history:
                    refreshed = zsh_smart_history.load_compacted_history(str(history_path), 100, 300, 0)

        self.assertEqual(refreshed, ["git add ."])
        load_recent_history.assert_called_once()


class PluginConfigurationTest(unittest.TestCase):
    def test_empty_keybind_remains_disabled(self) -> None:
        plugin_path = Path(__file__).resolve().parents[1] / "zsh-smart-history.plugin.zsh"

        result = subprocess.run(
            [
                "zsh",
                "-fc",
                f'ZSH_SMART_HISTORY_KEYBIND=""; source "{plugin_path}" >/dev/null 2>&1; '
                'print -r -- ${ZSH_SMART_HISTORY_KEYBIND}',
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.stdout, "\n")


class CompactCommandTest(unittest.TestCase):
    def test_compact_output_is_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            history_path = Path(tmpdir) / "history"
            history_path.write_text(": 1715200000:0;git status\n", encoding="utf-8")

            output = zsh_smart_history._compact_output(str(history_path), 100, 300, 3600)

        parsed = json.loads(output)
        self.assertEqual(parsed[0]["command"], "git status")


if __name__ == "__main__":
    unittest.main()
