# wolysh (`wsh`)

**Familiar commands. Better scripts. One small Linux shell.**

wolysh combines everyday Linux commands with a readable scripting language.
Commands stay commands; arithmetic, conditions, loops, and functions get their
own syntax. It is written in Zig and uses native Linux process and job control.

## Download

**[Get the latest Linux x86_64 release](https://github.com/dev-dami/wolysh/releases/latest)**

The release archive includes the shell, examples, license, and checksum.

![wolysh running in a terminal](assets/terminal-session.png)

## Why wolysh

- Run familiar commands, pipes, redirects, and globs.
- Write scripts with expressions, `if`, loops, and functions.
- Use built-in completion, syntax highlighting, history suggestions, and `Ctrl-R`.
- Manage foreground/background jobs with `Ctrl-Z`, `bg`, and `fg`.

```text
let workers = 4 * 2
if workers > 4 {
    print "Building with $workers workers"
    cargo build --jobs $workers
}
```

## Performance snapshot

![Bar charts of measured startup, loop, memory, and binary-size results](assets/benchmarks.svg)

Measurements are from one development machine, not a standardized benchmark.
The loop result covers this 20,000-iteration workload; results vary by machine
and workload.

<details>
<summary>Build from source</summary>

Linux x86_64 is the currently tested target. Building requires Zig 0.16.0:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/wsh
```

To install the source build, run `sudo install -m 0755 zig-out/bin/wsh /usr/local/bin/wsh`.

</details>

## Project status

Early stage and not a Bash or POSIX drop-in. Current gaps include subshells,
heredocs, `$((...))`, `2>&1`, and brace expansion. See the [language guide](docs/language.md)
for features, configuration, key bindings, and known limitations.

- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Demo script](examples/demo.wsh)

## License

MIT. See [LICENSE](LICENSE).
