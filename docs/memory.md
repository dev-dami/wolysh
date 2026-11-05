# Memory, safety, size and speed

This page sets the goals for memory safety, binary size and speed, and the
rules that every change must obey to reach them.

## Goals

1. **No undefined behaviour in release builds.** The release build is
   ReleaseFast. In ReleaseFast, integer overflow, an index out of bounds, a
   bad `@intCast` and `unreachable` do not panic: they are undefined
   behaviour. All arithmetic on values that come from input (scripts,
   variables, files, terminals, sockets) must be safe without the runtime
   checks.
2. **No leaks, double frees or uses after free.** The Memory guard job in CI
   must pass. At first it does not block a merge. When it is clean, remove
   `continue-on-error` from `.github/workflows/ci.yml` so that it does.
3. **Binary size does not grow without a reason.** CI writes the ReleaseFast
   and ReleaseSmall sizes to the job summary. A pull request that adds more
   than 2% to either size must say why.
4. **Speed does not go down.** Use `benchmarks/shell_bench.py` with
   `--baseline` against the last release before you claim a speed change.

## Ownership rules: owners, borrows and drops

Zig has no borrow checker, so these rules take its place. Each rule names who
frees the memory (the owner), who can only read it (a borrower), and when it
is freed (the drop).

### Allocators

| Allocator | Lifetime | Drop |
|---|---|---|
| `sh.gpa` | The shell process | One `free` for each allocation, in `Shell.deinit` or where the value is replaced |
| `sh.scratch()` (line arena) | One command line | `resetLineArena` frees all of it at once |
| Loop arena (`LoopScope` in `src/exec.zig`) | One loop iteration | `nextIteration` frees all of it at once |
| Process arena in `main` | The process | `arena_state.deinit()` at the end of `run` |

Never free scratch memory one allocation at a time. Never keep a slice of
scratch memory in shell state. Copy it with `sh.gpa` first.

### Owned values

- A function that returns memory the caller must free says so in its doc
  comment, and it takes the allocator as a parameter.
- Put `errdefer allocator.free(x)` directly after each allocation that a
  later `try` can skip past. This is the drop on the error path.
- Put `defer allocator.free(x)` directly after an allocation that does not
  leave the function. This is the drop on all paths.
- When a map `put` replaces a value, free the old key and value. Use
  `getOrPut` and free `value_ptr.*` before you write the new value.
- A struct that owns memory has a `deinit` that frees all of it. Call it with
  `defer` where the struct is made.

### Borrowed values

- A `[]const u8` parameter is a borrow. The callee must not free it, and it
  must not keep it after it returns. To keep it, copy it with `dupe`.
- A slice of `list.items` is not valid after the next `append`, `insert` or
  `resize` on that list. Take the slice again after you change the list.
- A pointer from `map.getPtr` or `getOrPut` is not valid after the next
  `put` or `remove` on that map.
- A value read from a shell variable can be freed when the script assigns or
  unsets that variable. Copy it before you run more script code.

### Integers

- Use `+%`, `-%` and `*%` where the shell must wrap as Bash does (arithmetic
  expansion). Use `+|` and `*|` where a large count must stop at the maximum
  (repeat counts, widths, sizes).
- Use `std.math.cast` instead of `@intCast` when the value comes from input.
  Handle `null` as an error or clamp the value.
- Before `a - b` on `usize`, make sure that `b <= a`, or use `a -| b`.
- Before `x[i]` or `x[a..b]` on input, make sure that `i < x.len` and
  `a <= b and b <= x.len`.

## Find memory bugs

Build with the checking allocator:

```sh
zig build -Doptimize=Debug -Dmem-guard=true
zig-out/bin/wsh -c 'your script here'
```

`-Dmem-guard` puts `std.heap.DebugAllocator` under the shell. At exit it
prints a stack trace for each leaked allocation. It stops on a double free.
It keeps freed pages mapped and fills them with `0xaa`, so a use after free
shows as garbage text. Loop arenas give their memory back after each
iteration, so a slice that was kept from an earlier iteration also shows as
garbage. The Debug build also panics on overflow and on an index out of
bounds, with a stack trace.

The unit tests use `std.testing.allocator`, which fails a test that leaks.
