# Contributing

Thanks for helping improve wolysh. The current implementation targets Linux
and is built with Zig 0.16.0. The interactive test suite uses Python 3 and a
pseudo-terminal.

## Verify changes

From the repository root, run:

```sh
zig build fmt
zig build test
zig build -Doptimize=ReleaseFast
python3 tests/pty_test.py
python3 tests/shell_compat_test.py
```

`zig build fmt` runs `zig fmt --check src build.zig build.zig.zon`; run
`zig fmt src build.zig build.zig.zon` to apply it. `zig build check` runs the
format check together with the unit tests. CI runs all five commands.

The test suites expect the ReleaseFast binary at `zig-out/bin/wsh` by default.
To run the PTY tests against another binary, set `WSH=/absolute/path/to/wsh`.

## Measure performance

Use the ReleaseFast build and run the benchmark separately from compilation
and tests:

```sh
python3 benchmarks/shell_bench.py --runs 15
```

To compare against a saved release binary, add
`--baseline /absolute/path/to/previous/wsh`. `--json` includes every sample and
binary checksums. See [benchmark methodology](benchmarks/README.md) before
making performance claims; CI checks correctness and does not gate on noisy
wall-clock ratios.

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

For a release, update the version in `build.zig` and `build.zig.zon`, move
changelog entries into a dated version section, and write
`docs/releases/vX.Y.Z.md`. The workflow verifies that the binary's version
matches the tag and uses that file as the release notes when present. It ships
the notes, language and agent guides, and repeatable benchmarks in the archive.
