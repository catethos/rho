# Rho — Agent Guidelines

## Architecture Notes

- **Mount system**: Mounts are registered via `Rho.MountRegistry.register/2` and discovered via ETS. All optional behavior (tools, prompt sections, bindings, lifecycle hooks) arrives through mounts implementing the `Rho.Mount` behaviour. Mounts are scoped (global or per-agent) and prioritized by registration order.
- **Channel system**: Channels are core infrastructure configured in `Rho.Application` and `Rho.Channel.Manager`, not part of the mount system.
- **CLI REPL**: The `Rho.Channel.Cli` GenServer spawns a blocking `IO.gets` loop in a linked process. That process must have the correct group leader to interact with the real terminal.

## Elixir/BEAM Pitfalls

- **`function_exported?/3` requires module loading**: A compiled module is NOT automatically loaded into the BEAM code server. `function_exported?/3` returns `false` for unloaded modules even if the function exists. Always call `Code.ensure_loaded!/1` before relying on `function_exported?/3`.
- **Group leader inheritance**: Supervised processes get a different group leader than the shell/mix task process. Any process that needs terminal IO (`IO.gets`, `IO.write`) must explicitly set its group leader to the terminal's group leader (the `:user` process). Pass it from the mix task entry point.
- **Avoid forever-pending `GenServer.call` for CLI entry points**: A mix task blocked inside `GenServer.call(__MODULE__, msg, :infinity)` interferes with terminal stdin ownership. Instead, have the call reply immediately and block the caller with a bare `receive`.

## Debugging Strategies

- When a feature silently does nothing, check whether the **registration/discovery layer** is working before debugging the feature itself. In hook-based architectures, the most common failure is hooks not being found.
- Use `Mod.__info__(:functions)` vs `function_exported?/3` to distinguish "function exists but module not loaded" from "function doesn't exist".
- When debugging IO/terminal issues, compare behavior between: (1) direct calls from the mix task process, (2) calls from supervised GenServer processes, and (3) calls from spawned processes — group leader differences are the usual culprit.
