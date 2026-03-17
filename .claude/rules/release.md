## Agent Rules — Release

### DO

- Run `make check` before any release commit
- Tag releases using semantic versioning: `vMAJOR.MINOR.PATCH`
  - `v0.x` — Media Driver phase (pre-stable)
  - `v1.0` — Media Driver feature-complete + wire-compatible
  - `v1.x` — Archive added
  - `v2.0` — Cluster added
- Update `CHANGELOG.md` before tagging — group by Added / Changed / Fixed
- Update `build.zig.zon` version field before tagging
- Verify interop smoke test against real Aeron Java client before `v1.0`

### DON'T

- Push directly to `main` — use a PR
- Skip CI checks with `--no-verify`
- Release from a dirty working tree
- Tag before `make check` passes cleanly
