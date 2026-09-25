# Contributing

Thanks for helping improve wolysh. The current implementation targets Linux
and is built with Zig 0.16.0. The interactive test suite uses Python 3 and a
pseudo-terminal.

## Verify changes

From the repository root, run:

```sh
zig build test
zig build -Doptimize=ReleaseFast
python3 tests/pty_test.py
```

The PTY tests expect the ReleaseFast binary at `zig-out/bin/wsh` by default. To
test another binary, set `WSH=/absolute/path/to/wsh`.

## Pull requests

- Explain the user-visible behavior or bug being addressed.
- Keep changes focused and document language limitations or compatibility
  changes in the README.
- Include the relevant verification results in the pull request description.
- Do not include local build output or editor configuration.

## Releases

Maintainers publish releases by pushing a `vX.Y.Z` tag after the change is
merged. The release workflow runs the test suite and builds the Linux x86_64
archive with the MIT license and examples.
