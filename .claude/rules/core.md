## Agent Rules — Core

### DO

- Use `make <target>` for all task execution — never run tools directly
- At session start: load MCP entities if available (`search_nodes` in tools); skip `CURRENT_TASK.md` when MCP active
- At session end: write state to `harus-aeron-zig:session` MCP entity
- Dispatch sub-agents for independent tasks — parallelize where possible
- Update `.agents/CONTEXT.md` when architecture or conventions change
- Stage files explicitly: `git add <specific files>` only
- Use `extern struct` for all wire-protocol types; add comptime size assertions
- Verify frame layouts against https://github.com/aeron-io/aeron before implementing

### DON'T

- Commit without user confirmation
- Use `git add -A` or `git add .`
- Install tools globally — use nix devShell or `make <target>` instead
- Use plan mode for small, well-scoped tasks — only for complex multi-step features
- Use `unreachable` in UDP receive paths — external data is untrusted
- Guess protocol details — always cross-reference the C++ or Java source
