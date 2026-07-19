# Local Java interop artifact

`aeron-all.jar` is a machine-local build cache and is intentionally ignored by
Git. Prepare it once with:

```bash
uv run scripts/trading.py ensure-java-artifact
```

The script first checks `test/interop/aeron-all.jar`. When the file exists,
the command is a no-op: Compose builds copy that exact file into the Java
images and do not download a Maven artifact or rebuild Aeron.

When the cache is absent, the script builds `aeron-all` from the checked-out
`vendor/aeron` source and copies the result here. This keeps the Java baseline
aligned with the vendored Aeron revision and makes the subsequent test, smoke,
and soak runs local and repeatable.
