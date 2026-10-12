# Performance workflow

Measure, then find, then change one thing, then measure again. Never optimise from a guess:
the first fix in the worked example below gained 6%, not the 50% it looked like it would.

Tools: `bench` (timing), `prof` (profiling, C and .NET), `bench-new` (BenchmarkDotNet starter).
In Neovim these are on `<leader>m` (see `KEYMAPS.md`). Results are kept in `.bench/` next to the code.

## The loop

| Step | Question | C | C# |
|---|---|---|---|
| 1. Measure | How long, and how noisy? | `bench './prog args'` | `bench 'dotnet app.dll'`, or BenchmarkDotNet |
| 2. Count | Why: CPU, cache, branches, GC? | `prof stat -- ./prog` | `prof net-counters -- dotnet app.dll` |
| 3. Find | Where does the time go? | `prof flame -- ./prog` | `prof net-trace -- dotnet app.dll` |
| 4. Memory | What allocates or leaks? | `prof heap -- ./prog` | `prof net-gc PID`, or counters |
| 5. Change | One change at a time | | |
| 6. Measure | Was it real? | `bench` again | `bench` again |

`bench` compares each run with the previous run of the same label and says whether the change
is bigger than the noise (twice the combined standard error). A result inside the noise is not
an improvement, however good it looks.

## C

Build for profiling with `prof build prog.c`: it uses `-O2 -g -fno-omit-frame-pointer`. Optimised,
because a debug build profiles code you will never ship; `-g` for names and line numbers;
frame pointers so `perf` can walk the stack.

- `prof stat`: **IPC** (instructions per cycle) is the first number to read. Around 1 or less
  means the CPU is waiting (memory, branches); 2 to 4 means it is busy doing real work.
  Then look at the cache and branch miss rates.
- `prof flame`: records with `perf`, opens speedscope. Use **Left Heavy** to see the biggest
  consumers first, **Sandwich** to see a function with all its callers and callees.
  `prof report` shows the same recording as text in the terminal, and `prof hotspot` opens it in
  hotspot (GUI: flame graph, caller/callee tables, per-line cost, timeline of threads).
- `prof callgrind`: exact instruction counts per function and line, about 50 times slower than
  normal. Use a small input. Deterministic, so it is good for comparing two versions. Opens in
  kcachegrind, where the **Callee Map** and **Source Code** tabs show the cost line by line.
- `prof heap`: allocation counts, peak memory, leaks, and the call site that allocates the most.

## C#

- Measure small pieces with **BenchmarkDotNet**: `bench-new Benchmarks` creates a project with a
  working example. Run it with `dotnet run -c Release -- --filter '*'`. Read the **Allocated**
  column as much as **Mean**: the cheapest code is often the one that allocates least.
- `prof net-counters` summarises the runtime counters. The ones that matter first:
  `gc.heap.total_allocated` (allocation rate), `gc.collections`, `gc.pause.time` (the share of
  time lost to GC) and `process.cpu.time`.
- `prof net-trace` samples where the CPU time goes and opens speedscope.
- `prof net-gc PID` dumps the heap of a running process and lists the types that hold the most memory.

## Rules that keep the numbers honest

1. Profile a **release** build. Debug builds measure the wrong thing.
2. Warm up and repeat. `bench` does 3 warmup runs and at least 10 timed runs.
3. Change **one** thing between measurements.
4. Keep the machine quiet: no builds, no browser video, plugged in. The power profile and CPU
   frequency change results by tens of percent.
5. Compare like with like: same input, same flags, same machine.
6. A profile shows where time is spent, not what is wrong. Ask why that function is slow before changing it.

## Worked example (C)

`hot.c` spent its time in `harmonic()` (57%, inlined into `main`) and `fib()` (42%) according to
`prof flame`. Replacing the inner division with a table of reciprocals and the recursion with a
loop gave **-5.9%**, real but small: at `-O2` the compiler already handled the divisions well.
The measurement corrected the guess, which is the point of doing it.

## Limits on this machine

- `kernel.perf_event_paranoid=2` (the default): `perf` profiles your own user-space code only.
  `prof flame` therefore records user-space call chains (`--user-callchains`). Kernel
  profiling needs a root change to that setting.
- Without `kcachegrind` installed, `prof callgrind` prints a text summary instead. The
  flame graph viewer for both C and .NET is speedscope (`npm install -g --prefix ~/.local speedscope`).
- `heaptrack` opens its GUI on its own after recording; `prof heap` passes `--record-only` and
  prints a text summary. Open the GUI yourself with `heaptrack_gui FILE`.
