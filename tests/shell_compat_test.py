#!/usr/bin/env python3
"""End-to-end checks for shell-script compatibility features."""
import pathlib
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"


def run_shell(command):
    return subprocess.run(
        [str(SHELL), "--no-config", "-c", command],
        cwd=ROOT,
        capture_output=True,
        timeout=10,
        check=False,
    )


class ShellCompatibilityTests(unittest.TestCase):
    def assert_success(self, result):
        self.assertEqual(
            result.returncode,
            0,
            f"wsh exited {result.returncode}; stdout={result.stdout!r}, stderr={result.stderr!r}",
        )

    def test_fd_duplication_before_stdout_redirect_preserves_original_stdout(self):
        with tempfile.TemporaryDirectory(prefix="wsh-compat-") as temp_dir:
            output_path = pathlib.Path(temp_dir) / "redirected.txt"
            result = run_shell(
                "/bin/sh -c 'printf out; printf err >&2' 2>&1 > "
                f"{shlex.quote(str(output_path))}"
            )

            self.assert_success(result)
            self.assertEqual(result.stdout, b"err")
            self.assertEqual(result.stderr, b"")
            self.assertEqual(output_path.read_bytes(), b"out")

    def test_fd_duplication_after_stdout_redirect_uses_redirected_stdout(self):
        with tempfile.TemporaryDirectory(prefix="wsh-compat-") as temp_dir:
            output_path = pathlib.Path(temp_dir) / "redirected.txt"
            result = run_shell(
                "/bin/sh -c 'printf out; printf err >&2' > "
                f"{shlex.quote(str(output_path))} 2>&1"
            )

            self.assert_success(result)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"")
            self.assertEqual(output_path.read_bytes(), b"outerr")

    def test_fd_duplication_routes_stderr_through_pipeline(self):
        result = run_shell(
            "/bin/sh -c 'printf out; printf err >&2' 2>&1 | /bin/cat"
        )

        self.assert_success(result)
        self.assertEqual(result.stdout, b"outerr")
        self.assertEqual(result.stderr, b"")

    def test_command_not_found_diagnostic_obeys_fd_redirection(self):
        result = run_shell("wsh-missing-compat-command 2>&1")

        self.assertEqual(result.returncode, 127)
        self.assertIn(b"command not found: wsh-missing-compat-command", result.stdout)
        self.assertEqual(result.stderr, b"")

    def test_unquoted_heredoc_delimiter_expands_variables(self):
        result = run_shell(
            'let name = "wolysh"\ncat <<EOF\nhello $name $(printf expanded)\nEOF\n'
        )

        self.assert_success(result)
        self.assertEqual(result.stdout, b"hello wolysh expanded\n")
        self.assertEqual(result.stderr, b"")

    def test_quoted_heredoc_delimiter_disables_expansion(self):
        result = run_shell("cat <<'EOF'\n$HOME $(printf expanded)\nEOF\n")

        self.assert_success(result)
        self.assertEqual(result.stdout, b"$HOME $(printf expanded)\n")
        self.assertEqual(result.stderr, b"")

    def test_double_quoted_heredoc_delimiter_preserves_ordinary_backslash(self):
        result = run_shell('cat <<"\\EOF"\nbody\n\\EOF\n')

        self.assert_success(result)
        self.assertEqual(result.stdout, b"body\n")
        self.assertEqual(result.stderr, b"")

    def test_empty_quoted_heredoc_delimiter(self):
        result = run_shell("cat <<''\nbody\n\n")

        self.assert_success(result)
        self.assertEqual(result.stdout, b"body\n")
        self.assertEqual(result.stderr, b"")

    def test_subshell_variable_changes_do_not_escape(self):
        result = run_shell(
            'let marker = "parent"\n'
            '(\n'
            '  let marker = "child"\n'
            '  print $marker\n'
            ')\n'
            'print $marker\n'
        )

        self.assert_success(result)
        self.assertEqual(result.stdout, b"child\nparent\n")
        self.assertEqual(result.stderr, b"")

    def test_subshell_runs_as_pipeline_stage(self):
        result = run_shell("(print outer; (print inner)) | /bin/cat\n")

        self.assert_success(result)
        self.assertEqual(result.stdout, b"outer\ninner\n")
        self.assertEqual(result.stderr, b"")

    def test_subshell_word_may_contain_parentheses(self):
        result = run_shell("(print foo(bar))\n")

        self.assert_success(result)
        self.assertEqual(result.stdout, b"foo(bar)\n")
        self.assertEqual(result.stderr, b"")

    def test_subshell_directory_change_does_not_escape(self):
        result = run_shell("(cd /tmp; /bin/pwd)\n/bin/pwd\n")

        self.assert_success(result)
        self.assertEqual(result.stdout, f"/tmp\n{ROOT}\n".encode())
        self.assertEqual(result.stderr, b"")

    def test_unterminated_heredoc_fails_with_a_syntax_error(self):
        result = run_shell("cat <<EOF\nbody without delimiter\n")

        self.assertEqual(result.returncode, 2)
        self.assertIn(b"here-document", result.stderr)


if __name__ == "__main__":
    if not SHELL.is_file():
        print(
            f"error: {SHELL} does not exist; run `zig build -Doptimize=ReleaseFast` first",
            file=sys.stderr,
        )
        sys.exit(2)
    unittest.main(verbosity=2)
