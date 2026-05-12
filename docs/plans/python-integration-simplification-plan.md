# Python Integration Simplification — Plan

**Date:** 2026-05-12
**Status:** Draft for review
**Goal:** Collapse two Python bridges (Pythonx + erlang_python) into one (erlang_python). Reduce surface area, lift the global-GIL bottleneck on the Python REPL tool, eliminate the known `Pythonx.Object` NIF bus-error footgun, and unify dep management onto one venv-based path.

---

## 1. Why simplify

Today the umbrella ships **both** bridges:

- `:pythonx ~> 0.4` — declared in `apps/rho_python/mix.exs:27`, `apps/rho_stdlib/mix.exs:34`.
- `:erlang_python ~> 2.3` — declared in `apps/rho_python/mix.exs:28`, `apps/rho_stdlib/mix.exs:35`.

Both embed CPython into the BEAM via NIFs; neither isolates Python crashes from the BEAM. The justification for keeping both was that Pythonx ships with `uv_init`-based dep declaration and erlang_python ships with stateful contexts. But:

- **erlang_python's contexts are strictly better than Pythonx's single global interpreter** for our workload (per-session REPL, parallel prose conversion). Pythonx serializes every call across the whole BEAM on its mutex.
- **The codebase already worked around a Pythonx-specific bug** — `apps/rho_stdlib/lib/rho/stdlib/tools/python/interpreter.ex:9-11` literally documents that passing `Pythonx.Object` globals back through the NIF causes bus errors on some platforms, so the REPL keeps its state in a Python-side `sys.modules['__rho_ns']` namespace. Under erlang_python, per-Erlang-process namespaces remove the need for this hack.
- **Dep management on erlang_python can stay declarative.** `uv_init` was the headline Pythonx feature; we can reproduce the "declare deps in Elixir, uv builds the venv on first start" pattern on erlang_python by running `uv venv` + `uv pip install` ourselves and calling `:py.activate_venv/1`. ~30 LOC.
- The codebase already has a second Python bridge in production (`PyAgent` via `:py.call`), so we're shipping both bridges in real builds. Drop one.

## 2. Surface area audit

Pythonx call sites (all must be ported or deleted):

| Location | What it does | Status |
|---|---|---|
| `apps/rho_stdlib/lib/rho/stdlib/tools/python/interpreter.ex` | Per-session Python REPL — `Pythonx.eval` with bindings, `stdout_device:` capture, persistent globals via `__rho_ns` sys.modules hack, Jupyter-style last-expression capture via AST split, matplotlib figure capture | **PORT** |
| `apps/rho_stdlib/lib/rho/stdlib/tools/python.ex` | Thin plugin wrapper over Interpreter | No change (calls `Interpreter.eval/3`) |
| `apps/rho_embeddings/lib/rho_embeddings/backend/pythonx.ex` | fastembed embeddings backend | **DELETE** — already disabled (`application.ex:8-13`), replaced by `Backend.OpenAI`. Behaviour module pattern means it's strictly removable. |
| `apps/rho_embeddings/lib/rho_embeddings/application.ex:11-15` | Commented-out `declare_deps(["fastembed==0.7.3", ...])` | Remove dead comment block. |
| `apps/rho_embeddings/lib/rho_embeddings/backend.ex:7-9` | Module doc referencing `Backend.Pythonx` | Update wording or remove reference. |
| `apps/rho_python/lib/rho_python/server.ex:79-96` | `do_init_pythonx/1`, pyproject builder, `:persistent_term` ready flag, `await_ready/1` | **REPLACE** with `do_init_venv/1` that runs `uv venv` + `uv pip install` and calls `:py.activate_venv/1` |
| `apps/rho_python/lib/rho_python.ex` | Public API: `declare_deps/1`, `ready?/0`, `await_ready/1`, `start_erlang_python/2` | Keep `declare_deps`, `ready?`, `await_ready`. Fold `start_erlang_python` into the unified init. Update moduledoc. |
| `apps/rho_python/test/rho_python_test.exs` | Two tests asserting `declare_deps` idempotence + `ready?` shape — and the comment says "deliberately avoid Pythonx.uv_init" | Keep tests; reword comment to "deliberately avoid the venv build". |
| `apps/rho_frameworks/lib/mix/tasks/rho_frameworks.backfill_embeddings.ex:10` | Doc says "Pythonx in prod, Fake in tests" | Update wording (no code change). |

Erlang_python call sites (existing — stay as is):

| Location | What it does |
|---|---|
| `apps/rho_python/lib/rho_python/server.ex:74-117` | `do_init_erlang_python/2` — starts `:erlang_python` app, adds py_agents dir to `sys.path`, optionally activates venv from `RHO_PY_AGENT_VENV`, exports env keys | Becomes the **only** init path. Reorganize but keep the behaviour. |
| `apps/rho_stdlib/lib/rho/stdlib/plugins/py_agent.ex` | `:py.call(module, fn, args)` for pydantic-ai agent bridge | No change required. |

mix.exs / supervision deltas:

| File | Change |
|---|---|
| `apps/rho_python/mix.exs` | Drop `{:pythonx, "~> 0.4"}`. Keep `{:erlang_python, "~> 2.3"}`. |
| `apps/rho_stdlib/mix.exs` | Drop `{:pythonx, "~> 0.4"}`. Keep `{:erlang_python, "~> 2.3"}`. |
| `mix.lock` | Regenerate after the deps drop. |
| `apps/rho_stdlib/lib/rho/stdlib/application.ex` | `maybe_setup_erlang_python/0` becomes `maybe_setup_python/0` (or keep name). Gating on `:python in all_plugin_names()` extended to also cover prose ingestion once Observer.Prose lands (separate plan). |

## 3. erlang_python feature mapping

For each Pythonx capability the REPL currently uses, here's the erlang_python equivalent:

| Pythonx feature | erlang_python equivalent | Note |
|---|---|---|
| `Pythonx.eval(code, locals)` | `:py.eval(code, locals)` returning `{:ok, term}` \| `{:error, {ExcType, Msg}}` | Locals map shape identical; result auto-converts (no manual `decode/1`). |
| `Pythonx.eval(code, locals, stdout_device: io)` | **No built-in.** Wrap user code Python-side: `sys.stdout = io.StringIO(); try: ... ; finally: out = sys.stdout.getvalue()`; then read `out` via a follow-up `:py.eval`. | One-time wrapper helper. |
| `Pythonx.decode/1` (NIF object → Erlang term) | Implicit on every call. | Removes ~5 sites in interpreter.ex. |
| Persistent globals across calls via `__rho_ns` sys.modules trick | Erlang_python's per-process namespace. Each `Interpreter` GenServer = its own Python namespace, kept alive for the life of the process. | Hack goes away. **Net loss of code.** |
| Bindings (`%{"__batch" => texts}`) | `:py.eval(code, %{__batch: texts})` — atoms-as-keys also work. | Trivial. |
| `Pythonx.uv_init/1` lazy venv build | `uv venv <path> && uv pip install --python <path> <deps>` + `:py.activate_venv("<path>")` | ~20-line helper in `RhoPython.Server`. |
| `:persistent_term` ready flag | Same pattern, keyed on venv-built vs not. | Direct port. |
| Async/parallelism | `num_contexts` + `py:spawn_call/await` if we ever need it. | Phase 3+. |

## 4. Module-by-module migration design

### 4.1 `RhoPython.Server` — unified init

Replace the two parallel init paths with one. Public API stays the same so callers (`RhoEmbeddings.Backend.OpenAI`, future `Observer.Prose`, future REPL backend) don't move.

```elixir
# apps/rho_python/lib/rho_python/server.ex
defmodule RhoPython.Server do
  use GenServer
  require Logger

  @ready_key {__MODULE__, :ready?}
  @venv_path_key {__MODULE__, :venv_path}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def declare_deps(deps), do: GenServer.call(__MODULE__, {:declare_deps, deps})

  def ready?, do: :persistent_term.get(@ready_key, false)

  def await_ready(timeout \\ 30_000) do
    if ready?() do
      :ok
    else
      try do
        GenServer.call(__MODULE__, :init, timeout)
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
      end
    end
  end

  # py_agents_dir + env_keys folded into init opts; previous start_erlang_python/2
  # becomes a thin wrapper that declares additional setup before calling await_ready/1.
  def configure_py_agents(py_agents_dir, env_keys),
    do: GenServer.call(__MODULE__, {:configure_py_agents, py_agents_dir, env_keys})

  @impl true
  def init(_) do
    {:ok, %{
       deps: MapSet.new(),
       py_agents_dir: nil,
       env_keys: [],
       initialized?: false
     }}
  end

  @impl true
  def handle_call({:declare_deps, deps}, _from, state) do
    {:reply, :ok, %{state | deps: MapSet.union(state.deps, MapSet.new(deps))}}
  end

  def handle_call({:configure_py_agents, dir, keys}, _from, state) do
    {:reply, :ok, %{state | py_agents_dir: dir, env_keys: keys}}
  end

  def handle_call(:init, _from, %{initialized?: true} = state),
    do: {:reply, :ok, state}

  def handle_call(:init, _from, state) do
    do_init(state)
    :persistent_term.put(@ready_key, true)
    {:reply, :ok, %{state | initialized?: true}}
  end

  defp do_init(state) do
    {:ok, _} = Application.ensure_all_started(:erlang_python)

    venv = resolve_venv_path()
    deps = state.deps |> MapSet.to_list() |> Enum.sort()

    if deps != [] do
      build_venv(venv, deps)
    end

    :ok = :py.activate_venv(venv)
    :persistent_term.put(@venv_path_key, venv)

    if state.py_agents_dir do
      :py.exec(~s|
        import sys, os
        if '#{state.py_agents_dir}' not in sys.path:
            sys.path.insert(0, '#{state.py_agents_dir}')
      |)
      export_env_keys_to_python(state.env_keys)
    end

    Logger.info("RhoPython initialized: venv=#{venv}, deps=#{inspect(deps)}")
  end

  # --- venv lifecycle ---

  defp resolve_venv_path do
    System.get_env("RHO_PY_VENV") ||
      Path.join([System.user_cache_dir() || System.tmp_dir!(), "rho", "py_venv"])
  end

  defp build_venv(venv, deps) do
    File.mkdir_p!(Path.dirname(venv))

    unless File.exists?(Path.join(venv, "pyvenv.cfg")) do
      {_, 0} = System.cmd("uv", ["venv", venv], stderr_to_stdout: true)
    end

    {_, 0} =
      System.cmd("uv", ["pip", "install", "--python", venv | deps], stderr_to_stdout: true)
  end

  defp export_env_keys_to_python(keys) do
    for k <- keys, v = System.get_env(k), v != nil do
      escaped = v |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
      :py.exec("os.environ['#{k}'] = '#{escaped}'")
    end
  end
end
```

Key behaviours preserved:
- `declare_deps/1` aggregates from any number of consumer apps before first `await_ready/1`.
- `ready?/0` short-circuit via `:persistent_term` — same hot-path cost.
- `await_ready/1` is the only thing that triggers the (potentially slow) venv build. Idempotent on second call.
- `configure_py_agents/2` replaces `start_erlang_python/2`; the previous function name can stay as an alias for one release if anything in the codebase still uses it. (Currently only `apps/rho_stdlib/lib/rho/stdlib/application.ex:72` does.)

Cold-start cost: first `await_ready/1` runs `uv venv` (~2 s) + `uv pip install` (varies — 5–30 s for prose deps). Subsequent boots find the venv populated and skip straight to `:py.activate_venv`. Production should set `RHO_PY_VENV` to a stable path and (optionally) pre-build the venv into the Docker image.

### 4.2 `Rho.Stdlib.Tools.Python.Interpreter` — REPL port

This is the largest port. ~250 LOC. Public API stays identical:

```elixir
@spec eval(session_id :: String.t(), code :: String.t(), workspace :: String.t() | nil) ::
        {disposition :: :ok | :final | :error, output :: String.t() | tuple()}
```

Internal redesign:

```elixir
defmodule Rho.Stdlib.Tools.Python.Interpreter do
  use GenServer
  require Logger

  # Pre-built wrapper that:
  #  1. Redirects sys.stdout to an io.StringIO buffer.
  #  2. Parses user code, splits last Expr off via ast.
  #  3. exec()s the rest, eval()s the last expr (Jupyter-style).
  #  4. Restores sys.stdout.
  #  5. Returns a dict with stdout + result keys (both Erlang-serializable).
  #
  # Crucially, this runs INSIDE the GenServer's Erlang process, so erlang_python's
  # implicit per-process namespace means variables persist across calls automatically.
  # No __rho_ns sys.modules hack required.
  @eval_template ~S"""
  import sys as __s, ast as __a, io as __io

  __captured = __io.StringIO()
  __orig_stdout = __s.stdout
  __s.stdout = __captured
  __result = None
  __err = None
  try:
      __tree = __a.parse(__user_code, '<rho>')
      if __tree.body and isinstance(__tree.body[-1], __a.Expr):
          __last = __tree.body.pop()
          if __tree.body:
              exec(compile(__a.fix_missing_locations(__a.Module(body=__tree.body, type_ignores=[])), '<rho>', 'exec'), globals())
          __result = eval(compile(__a.fix_missing_locations(__a.Expression(body=__last.value)), '<rho>', 'eval'), globals())
      else:
          exec(compile(__tree, '<rho>', 'exec'), globals())
  finally:
      __s.stdout = __orig_stdout

  if isinstance(__result, dict) and 'final' in __result and 'result' in __result:
      __final = __result
  elif __result is not None:
      __final = {'final': True, 'result': __result}
  else:
      __final = None

  {'stdout': __captured.getvalue(), 'result': __final}
  """

  # --- public ---

  def eval(session_id, code, workspace \\ nil), do: ...  # unchanged

  # --- internals ---

  @impl true
  def init(opts) do
    workspace = Keyword.get(opts, :workspace)
    if workspace, do: :py.exec("import os; os.chdir(#{escape(workspace)})")
    matplotlib_to_agg()
    {:ok, %{workspace: workspace}}
  end

  @impl true
  def handle_call({:eval, code}, _from, state) do
    files_before = if state.workspace, do: snapshot_files(state.workspace), else: %{}

    case :py.eval(@eval_template, %{__user_code: code}) do
      {:ok, %{stdout: stdout, result: result_or_nil}} ->
        image_paths = capture_matplotlib_figures(state.workspace)
        changed = if state.workspace, do: detect_changed_files(state.workspace, files_before), else: []
        {:reply, format_output(stdout, result_or_nil, changed, image_paths), state}

      {:error, {exc_type, msg}} ->
        {:reply, {:error, {:eval_failed, "#{exc_type}: #{msg}"}}, state}
    end
  end

  defp matplotlib_to_agg do
    :py.exec(~S"""
    try:
        import matplotlib
        matplotlib.use('Agg')
    except ImportError:
        pass
    """)
  end

  defp capture_matplotlib_figures(workspace) do
    output_dir = workspace || System.tmp_dir!()
    code = """
    try:
        import matplotlib.pyplot as plt
        import time
        ts = int(time.time() * 1000)
        paths = []
        for i, fnum in enumerate(plt.get_fignums()):
            fig = plt.figure(fnum)
            p = '#{output_dir}' + f'/plot_{ts}_{i + 1}.png'
            fig.savefig(p, format='png', bbox_inches='tight', dpi=150)
            paths.append(p)
        plt.close('all')
        paths
    except ImportError:
        []
    """
    case :py.eval(code) do
      {:ok, paths} when is_list(paths) -> paths
      _ -> []
    end
  end

  # format_output, snapshot_files, detect_changed_files, escape — unchanged
end
```

Behaviour-preservation map:

| Pythonx behaviour | New behaviour | Verification |
|---|---|---|
| Persistent globals across eval calls in the same session | erlang_python's implicit per-Erlang-process Python namespace — survives as long as the Interpreter GenServer survives | Test: assign `A = [1,2,3]`, then in a second eval `A` resolves to `[1,2,3]` |
| Last-expression value returned | Same Python AST split, just running under `:py.eval` instead of `Pythonx.eval` | Test: `1 + 1` returns `2` |
| Stdout capture | `sys.stdout = io.StringIO()` redirect in the template | Test: `print("hi"); 42` returns stdout `"hi"` + result `42` |
| `{"final": False, "result": ...}` agent-control protocol | Same Python dict, returned as Erlang map | Test: code returning that dict yields `:ok` disposition (not `:final`) |
| Matplotlib figure capture | Separate `:py.eval` after the user code | Test: `plt.plot([1,2,3])` → PNG file lands in workspace |
| Workspace file change detection | Elixir-side `snapshot_files/2` — unchanged | Test: `with open("x", "w") as f: f.write("a")` → `x` appears in changed-files list |
| Bus error workaround via `__rho_ns` sys.modules trick | **Deleted.** Per-process Python namespace makes it unnecessary | Verify by running the existing REPL test suite + a stress test with many sessions in parallel |

Per-process namespace caveat (must validate): the README says "Each Erlang process gets its own isolated Python namespace." We need to confirm what "Erlang process" means in the dirty-NIF context — is it the calling BEAM process, or one of erlang_python's worker pthreads? If the latter, the namespace is tied to a pool worker, not the GenServer, and we'd need explicit `py:context/1` references in state.

**Validation step (Phase 0):** before committing to the redesign, write a 30-line spike that:
1. Starts `:erlang_python`.
2. From two distinct Elixir processes, does `:py.eval("x = 1", %{})` and then `:py.eval("x", %{})` from the same processes — assert each sees its own `x`.
3. Assert cross-process isolation (process A's `x` invisible to B).

If isolation isn't actually per-Erlang-process, fall back to `py:context/1` held in GenServer state and pass it explicitly: `:py.eval(ctx, code, locals)`. ~5 extra lines in Interpreter; no other module affected.

### 4.3 `RhoEmbeddings.Backend.Pythonx` — delete

Currently `apps/rho_embeddings/lib/rho_embeddings/application.ex:7-13` says the production backend is `Backend.OpenAI` and the Pythonx backend is commented out. The Pythonx backend file is dead code but not yet deleted.

Plan:
- Delete `apps/rho_embeddings/lib/rho_embeddings/backend/pythonx.ex`.
- Strip the commented-out `declare_deps(["fastembed==0.7.3", "numpy>=2.0"])` from `application.ex` and replace the explanatory comment with a one-liner pointing at git history.
- Update `apps/rho_embeddings/lib/rho_embeddings/backend.ex:7-9` moduledoc — remove the bullet about `Backend.Pythonx`. If we want to keep an option for a non-HTTP backend in the future, add a TODO referencing this plan rather than a stale code reference.
- Update `apps/rho_frameworks/lib/mix/tasks/rho_frameworks.backfill_embeddings.ex:10` moduledoc — replace "Pythonx in prod" with "OpenAI (HTTP) in prod".

When fastembed re-enables (Pillow upstream fix), the new backend is `RhoEmbeddings.Backend.ErlangPython` and follows the Interpreter pattern: one GenServer holding loaded-model state in a Python namespace, `:py.eval` for inference.

### 4.4 `RhoPython` public API

Tighten the moduledoc and drop the section that talks about "Pythonx (library Python)" vs "erlang_python (stateful agent-loop Python)". After this change there's only one runtime — erlang_python — and the public functions are:

```elixir
@doc "Declare Python deps (idempotent). Call from consumer Application.start/2."
@spec declare_deps([String.t()]) :: :ok

@doc "Returns true once the shared venv is built and activated."
@spec ready?() :: boolean()

@doc "Block until init completes (builds venv on first call). Subsequent calls return :ok cheaply."
@spec await_ready(timeout()) :: :ok | {:error, :timeout}

@doc """
Tell the init step to expose a directory on Python's sys.path and re-export
the given env vars to os.environ. Idempotent. Call this BEFORE await_ready/1
so the configuration is applied during init.
"""
@spec configure_py_agents(Path.t(), [String.t()]) :: :ok
```

`start_erlang_python/2` is renamed to `configure_py_agents/2`. The old name can ship as a 1-line `@deprecated` alias for one release if any downstream user wants graceful migration; in this repo there's one caller (`apps/rho_stdlib/lib/rho/stdlib/application.ex:72`) so we can do a hard rename.

## 5. Phasing (PR sequence)

Each phase is one mergeable PR. Each leaves the tree green and the product working end-to-end.

### Phase 0 — Validation spike (don't merge, just learn)

1. Write a minimal escript or `mix run --eval` that starts `:erlang_python` and confirms:
   - `:py.eval/2` returns `{:ok, term}` with auto-converted values.
   - Per-Elixir-process namespace isolation works as the README implies (or doesn't — see §4.2 caveat).
   - `:py.activate_venv/1` accepts a `uv venv`-built venv and `import` calls succeed against `uv pip install`-installed packages.
   - Stdout-redirect-via-`io.StringIO` pattern captures correctly across try/finally.
2. Time the cold-start cost of `uv venv` + `uv pip install` against the deps we'll need (matplotlib + numpy + pandas — current prod Python REPL workload).
3. Decide: implicit per-process namespace ✓ or explicit `py:context/1` fallback. Update Phase 2 accordingly.

**Output:** a short notes file pinning the answer for §4.2 and §5.0.

### Phase 1 — Delete dead Pythonx backend

PR 1 — purely deletions, low risk.

1. Delete `apps/rho_embeddings/lib/rho_embeddings/backend/pythonx.ex`.
2. Update `apps/rho_embeddings/lib/rho_embeddings/application.ex` (remove the commented-out block, simplify the comment).
3. Update `apps/rho_embeddings/lib/rho_embeddings/backend.ex` moduledoc.
4. Update `apps/rho_frameworks/lib/mix/tasks/rho_frameworks.backfill_embeddings.ex` moduledoc.
5. `mix compile --warnings-as-errors && mix test`.

No mix.exs change here — Pythonx is still needed by the REPL Interpreter. Just removing dead references.

### Phase 2 — Port the Python REPL Interpreter

PR 2 — the substantive work. Highest risk, gated by Phase 0's validation.

1. Add a new dep-management call to `Rho.Stdlib.Application.start/2`: if the `:python` plugin is mounted, `RhoPython.declare_deps(["matplotlib", "numpy", "pandas"])` (mirroring the current implicit prod-Python dep set).
2. Rewrite `Rho.Stdlib.Tools.Python.Interpreter` per §4.2. Keep its public API (`eval/3`, `session_info/1`, `stop/1`) byte-identical so `Rho.Stdlib.Tools.Python` and its callers don't move.
3. Rewrite `RhoPython.Server` per §4.1. Keep `declare_deps/1`, `ready?/0`, `await_ready/1` signatures unchanged; rename `start_erlang_python/2` to `configure_py_agents/2`.
4. Update `apps/rho_stdlib/lib/rho/stdlib/application.ex:69-72` to call the renamed function.
5. Drop `{:pythonx, "~> 0.4"}` from `apps/rho_python/mix.exs` and `apps/rho_stdlib/mix.exs`. Regenerate `mix.lock`.
6. Update `apps/rho_python/lib/rho_python.ex` moduledoc + the test file's comment.
7. Run the existing tests: `mix test --app rho_python`, `mix test --app rho_stdlib`. Add a fresh Interpreter integration test if none exists (the audit showed `apps/rho_stdlib/test/rho/stdlib/data_table_test.exs` & co exist but no Python REPL test file — worth adding one as part of this PR, even minimal: print/result/persistence/matplotlib).
8. Manually exercise the Python REPL via `mix rho.run` (or whichever entry point is fastest) against a simple `.rho.exs` mounting the `:python` plugin. Confirm:
   - `print("hi"); 1+1` returns "hi\n2".
   - Defining `A = [1,2,3]` in one call and using `A` in a second call works.
   - `plt.plot([1,2,3])` saves a PNG into the workspace.
   - Stack-trace-on-error returns a clean `:error` tuple.

### Phase 3 — Polish & docs

PR 3 — tidy-up after the substantive work lands.

1. Update `CLAUDE.md` "App boundaries / `apps/rho_python/`" section — drop mentions of "Pythonx + erlang_python", say "embeds CPython via erlang_python, builds a uv-managed venv from declared deps".
2. Optional: introduce an `RHO_PY_PREWARM=1` env var that calls `RhoPython.await_ready/1` from `Rho.Stdlib.Application.start/2` so first-upload / first-REPL-call latency is paid at boot. Default off.
3. Add telemetry events for `[:rho_python, :init, :stop]` (duration, deps count) and `[:rho_python, :eval]` (duration, error?). Optional but useful for ops.
4. If we want true parallel sessions, set `num_contexts: System.schedulers_online()` for erlang_python via app env. Each Interpreter GenServer can then run without blocking another. Requires confirming each GenServer maps to its own context — Phase 0 spike output decides this.

After Phase 3 the only Python bridge in the umbrella is erlang_python and the only Python-deps surface in Elixir is `RhoPython.declare_deps/1`.

## 6. Risks & mitigations

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| **Per-process namespace ≠ per-Elixir-process** (Phase 0 invalidates §4.2's assumption) | Medium | Reshapes Interpreter port — need explicit `py:context/1` plumbing | Phase 0 spike resolves before Phase 2 starts. Fallback path adds ~5 LOC and stays inside Interpreter. |
| Matplotlib `Agg` backend init differs in behaviour under erlang_python vs Pythonx | Low | Plots may fail to capture | Phase 0 includes a matplotlib smoke test. |
| `:py.eval` stdout-redirect pattern leaks stdout when user code raises | Medium | Stdout missing on error → confusing UX | Template uses `try / finally: sys.stdout = __orig_stdout`. Confirmed pattern in Phase 0. |
| `uv` not installed on the host | Low (we use it elsewhere) | Boot crash | Fall back to `python -m venv` + `python -m pip install` if `uv` missing. Document the `RHO_PY_VENV` env override. |
| Venv build takes too long on first boot in production | Medium | Slow cold-start, possibly LB timeout | (a) Pre-build the venv into the Docker image; (b) optional `RHO_PY_PREWARM=1`; (c) `await_ready/1`'s 30s timeout returns `{:error, :timeout}` cleanly so callers degrade. |
| Active Python REPL sessions break mid-deploy if the deployed venv path changes | Low | Sessions hit `ModuleNotFoundError` until restart | Pin `RHO_PY_VENV` to a stable path across deploys. |
| Some Pythonx-only behaviour we missed | Low | Latent regression | Phase 2 PR includes the Interpreter integration test as a hard gate; no merge without green REPL exercise. |
| `RhoEmbeddings.Backend.Pythonx` deletion breaks someone's downstream config | Very low (commented-out in production) | Build error | Phase 1 grep-audit before delete; only delete if no live `config :rho_embeddings, backend: RhoEmbeddings.Backend.Pythonx` anywhere in `config/`. |

## 7. Rollback / safety

- **After Phase 1**: trivial revert — single PR, only deletions.
- **After Phase 2**: revert the PR to restore `Pythonx.eval`-based interpreter and re-add `{:pythonx, "~> 0.4"}`. The Phase 2 PR should be one atomic commit (or at most: Interpreter port + mix.exs drop + Server rewrite as a single squash-merge) so rollback is one git revert.
- **In production hot-path**: if the Interpreter port misbehaves, `:python` plugin can be unmounted in `.rho.exs` per-agent until the fix lands. The rest of the product (no Python deps) keeps shipping.

## 8. Acceptance criteria

After Phase 3 lands, all of the following hold:

1. `mix.lock` does not mention `pythonx`. `grep -r Pythonx apps/` returns only documentation context (not code).
2. `:erlang_python` is the only Python bridge declared in any `mix.exs` under `apps/`.
3. The Python REPL tool (`:python` plugin) behaves identically to its pre-port behaviour across the verification matrix in §4.2 — persistent globals, last-expression return, stdout capture, matplotlib capture, `{final, result}` agent-control protocol, error mapping.
4. `RhoPython.declare_deps/1` + `await_ready/1` builds a uv-managed venv on first call and is cheap on subsequent calls. Verified by a fresh-checkout boot.
5. `mix test` is green; new Interpreter integration test exists.
6. `CLAUDE.md` reflects the simplified one-bridge architecture.
7. Optional but desirable: a single concurrent-REPL test demonstrates that two sessions running `time.sleep(2)` in parallel complete in ~2 s, not ~4 s — confirming the Pythonx global-lock contention is gone.

## 9. Open questions for review

1. **`uv` vs `pip` for the venv build.** Plan uses `uv` (cached interpreter, faster solver). Acceptable to require `uv` as a host dependency, or should we fall back to stdlib `venv` + `pip`? In dev/CI we already use `uv`. Production Dockerfile would bake `uv` in.
2. **Default venv path.** Plan uses `RHO_PY_VENV` env, falling back to `$XDG_CACHE_HOME/rho/py_venv`. Production likely wants a baked-into-image path like `/opt/rho/py_venv`. Document but don't enforce.
3. **Should Phase 2 also bump erlang_python to `num_contexts: schedulers_online()`?** Plan defers to Phase 3 to keep Phase 2's surface small. But if we want to claim "removed the global GIL bottleneck" as a Phase 2 outcome, we'd merge them.
4. **Keep `start_erlang_python/2` as a deprecated alias for one release?** Repo has one caller; hard rename is easier. Confirm there's no external consumer.
5. **`Backend.OpenAI` for embeddings stays in place after this work.** Re-enabling fastembed (when Pillow ships) becomes a new `Backend.ErlangPython` written from scratch, not a revival of the deleted `Backend.Pythonx`. Confirm that's the direction.
