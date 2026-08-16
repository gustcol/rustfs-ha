# Dependency Notes

This repository intentionally pins a handful of dependencies below their latest published major/minor
version because the newer releases changed APIs in ways that break code in this workspace. This document
records why each pin exists so it isn't "fixed" by an automated bump without checking first.

## `ratelimit` — pinned to `0.10`

`ratelimit` 2.0 changed the builder and accessor API in ways that are not source-compatible with 0.10:

- `Ratelimiter::builder(...)` moved from a multi-argument constructor to a single-argument form.
- `rate()` now returns `f64` instead of the integer type used in 0.10.
- `set_available()` was removed entirely.

`crates/ecstore`'s bandwidth monitor calls into this API directly, so bumping past 0.10 requires rewriting
that call site, not just editing `Cargo.toml`.

## `datafusion` / `object_store` — pinned to `52.x` / `0.12`

`datafusion` 53 pulls in `object_store` 0.13, and that pairing changed the `ObjectStore` trait surface that
`crates/s3select-api` implements to expose RustFS storage to DataFusion's query engine. The trait changes
are not additive — existing implementations no longer satisfy the trait as written. `datafusion` and
`object_store` must be bumped together (they are a matched pair upstream); bumping only one will fail to
compile or silently pull an incompatible transitive version.

## OpenTelemetry crates — must stay on one minor family (currently `0.32`)

All `opentelemetry*` crates (`opentelemetry`, `opentelemetry_sdk`, `opentelemetry-otlp`,
`opentelemetry-appender-tracing`, `opentelemetry-semantic-conventions`, `opentelemetry-stdout`,
`tracing-opentelemetry`) must resolve to the **same minor version**. A mixed `0.31`/`0.32` tree in the
lockfile fails to compile in `rustfs-obs` — the crates share internal types across the family that are not
compatible across minor versions, even though semver would normally suggest otherwise for pre-1.0 crates.

Within the `0.32` line, note that `opentelemetry-appender-tracing` renamed the feature
`experimental_use_tracing_span_context` to `experimental_span_attributes`, and dropped
`spec_unstable_logs_enabled`. `Cargo.toml` in this workspace already reflects the renamed feature; if you
see a "feature not found" error while bumping, check the crate's changelog for a feature rename before
assuming the pin is wrong.

## How to upgrade safely

1. **Upgrade the whole family together.** Never bump one `opentelemetry*` crate, or `datafusion` without
   `object_store`, in isolation. Check each crate's changelog for renamed/removed features and API changes
   before touching `Cargo.toml`.
2. **Do a full release build before merging.** `cargo check` is not sufficient — several of the breaking
   changes above only surface with all features enabled, or only in code paths exercised by
   `crates/ecstore` and `crates/s3select-api`. Run `cargo build --release --workspace` locally.
3. **Treat the CI nix job as advisory, not a gate.** The CI nix build is currently unreliable because of
   upstream cache rate limits, so a green CI run is not proof the dependency set actually compiles. A local
   release build is the mandatory gate before merging a dependency bump, regardless of what CI reports.
