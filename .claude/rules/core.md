## Agent Rules — Core

### DO

- Use `make <target>` for all task execution — never run tools directly
- At session start: load state from the project-local asobi graph (`asobi show harus-aeron-zig harus-aeron-zig:session`)
- At session end: write state to the `harus-aeron-zig:session` asobi entity
- Dispatch sub-agents for independent tasks — parallelize where possible
- Record architecture/convention changes on the `harus-aeron-zig` asobi project entity
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
