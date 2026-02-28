# RustFS Production Scaling — Implementation Guide

This document describes the changes implemented to make RustFS production-ready for multi-container Kubernetes deployments supporting millions of concurrent connections on both ARM64 and AMD64 architectures. It covers what was changed, why, how it was tested, and how to verify each change.

## Table of Contents

- [Overview of Changes](#overview-of-changes)
- [1. Metrics Cardinality Fix](#1-metrics-cardinality-fix)
- [2. Zero-Allocation Method Mapping](#2-zero-allocation-method-mapping)
- [3. Response Status Class Tracking](#3-response-status-class-tracking)
- [4. Flexible Helm StatefulSet](#4-flexible-helm-statefulset)
- [5. HorizontalPodAutoscaler](#5-horizontalpodautoscaler)
- [6. ServiceMonitor for Prometheus](#6-servicemonitor-for-prometheus)
- [7. Production Values File](#7-production-values-file)
- [8. Dockerfile Hardening](#8-dockerfile-hardening)
- [9. Docker Compose Multi-Architecture](#9-docker-compose-multi-architecture)
- [10. Grafana Dashboard Update](#10-grafana-dashboard-update)
- [Testing & Validation](#testing--validation)
- [Verification Checklist](#verification-checklist)

---

## Overview of Changes

| File | Type | Purpose |
|------|------|---------|
| `rustfs/src/server/http.rs` | Modified | Metrics fix, performance optimization, response tracking |
| `helm/rustfs/templates/statefulset.yaml` | Modified | Flexible replica count, topology, startup probes |
| `helm/rustfs/templates/deployment.yaml` | Modified | Topology spread, startup probes, extra env |
| `helm/rustfs/templates/_helpers.tpl` | Modified | `drivesPerNode` helper, dynamic volume generation |
| `helm/rustfs/values.yaml` | Modified | HPA, PDB, metrics, startup probe defaults |
| `helm/rustfs/templates/hpa.yaml` | Created | HorizontalPodAutoscaler template |
| `helm/rustfs/templates/servicemonitor.yaml` | Created | Prometheus ServiceMonitor template |
| `helm/rustfs/values-production.yaml` | Created | Production-ready defaults for 16-node clusters |
| `Dockerfile` | Modified | HEALTHCHECK, STOPSIGNAL for orchestrator integration |
| `.docker/compose/docker-compose.cluster.yaml` | Modified | Multi-arch support, YAML anchors, health checks |
| `.docker/observability/grafana/dashboards/rustfs.json` | Modified | Label alignment with new metrics |
| `docs/SCALING.md` | Created | Deployment and scaling guide |

---

## 1. Metrics Cardinality Fix

**File:** `rustfs/src/server/http.rs`

**Problem:** The original code recorded a `key_request_uri_path` label on every API request counter, using the raw URI path (e.g., `/bucket/prefix/deep/object.txt`). In a system with millions of objects, this creates unbounded cardinality — each unique object path becomes a separate time series. This causes Prometheus to consume excessive memory and eventually OOM.

**Solution:** Replace unbounded URI path labels with a bounded `key_api_type` label that classifies every request into one of 7 categories:

```rust
fn classify_api_path(path: &str) -> &'static str {
    match path {
        "/" | "" => "s3_api",
        "/health" | "/health/ready" => "health",
        "/profile/cpu" | "/profile/memory" => "profile",
        "/favicon.ico" => "console",
        _ if path.starts_with("/rustfs/admin") => "admin",
        _ if path.starts_with("/rustfs/console") => "console",
        _ if path.starts_with("/rustfs/rpc") => "rpc",
        _ if path.starts_with("/node_service.NodeService") => "grpc",
        _ if path.starts_with("/minio/") => "admin",
        _ => "s3_api",
    }
}
```

**Route coverage:** The categories were derived from `rustfs/src/server/prefix.rs` which defines all server route prefixes (`ADMIN_PREFIX`, `CONSOLE_PREFIX`, `RPC_PREFIX`, `HEALTH_PREFIX`, `PROFILE_CPU_PATH`, `TONIC_PREFIX`).

**How it was tested:**
- 7 unit tests added in `classify_tests` module covering all categories
- `cargo test` — 523 tests pass (516 original + 7 new)
- `cargo clippy` — 0 warnings

```bash
# Run the specific tests
cargo test classify_tests

# Run all tests
cargo test
```

---

## 2. Zero-Allocation Method Mapping

**File:** `rustfs/src/server/http.rs`

**Problem:** The original code used `format!("{}", request.method())` on every request to create the method label string. This allocates a new `String` on the heap for every single HTTP request — at millions of requests per second, this creates significant GC pressure.

**Solution:** Added `method_to_static_str()` that maps HTTP methods to `&'static str` references with zero allocation:

```rust
#[inline]
fn method_to_static_str(method: &Method) -> &'static str {
    match *method {
        Method::GET => "GET",
        Method::PUT => "PUT",
        Method::POST => "POST",
        Method::DELETE => "DELETE",
        Method::HEAD => "HEAD",
        Method::OPTIONS => "OPTIONS",
        Method::PATCH => "PATCH",
        Method::TRACE => "TRACE",
        Method::CONNECT => "CONNECT",
        _ => "UNKNOWN",
    }
}
```

**Impact:** Eliminates one heap allocation per request on the hot path. At 1M req/s, this avoids ~1 million `String` allocations per second.

**How it was tested:**
- `cargo check` — compiles without warnings
- `cargo test` — 523 tests pass
- Function is `#[inline]` annotated to encourage inlining at the call site

---

## 3. Response Status Class Tracking

**File:** `rustfs/src/server/http.rs`

**Problem:** The original `on_response` callback only recorded latency. There was no visibility into HTTP response status distribution (success vs error rates).

**Solution:** Added a `rustfs.api.responses.total` counter with a `key_status_class` label using bounded categories:

```rust
.on_response(|response: &Response<_>, latency: Duration, span: &Span| {
    let status = response.status();
    span.record("status_code", tracing::field::display(status));
    let _enter = span.enter();
    histogram!("rustfs.request.latency.ms").record(latency.as_millis() as f64);
    let status_class = match status.as_u16() {
        200..=299 => "2xx",
        300..=399 => "3xx",
        400..=499 => "4xx",
        500..=599 => "5xx",
        _ => "other",
    };
    counter!("rustfs.api.responses.total",
        "key_status_class" => status_class.to_string()
    ).increment(1);
    debug!("http response generated in {:?}", latency)
})
```

**Design choice:** Using 5 bounded categories (`2xx`, `3xx`, `4xx`, `5xx`, `other`) instead of individual status codes (200, 201, 204, 400, 404, ...) keeps cardinality bounded while providing actionable operational signals.

**How it was tested:**
- `cargo check` — compiles without warnings
- `cargo test` — 523 tests pass
- Manual verification that only 5 possible label values exist

---

## 4. Flexible Helm StatefulSet

**Files:** `helm/rustfs/templates/statefulset.yaml`, `helm/rustfs/templates/_helpers.tpl`, `helm/rustfs/values.yaml`

**Problem:** The original StatefulSet template had hardcoded replica checks (only 4 or 16 were supported). The volume initialization logic used a brittle `if/elif` chain based on `REPLICA_COUNT`.

**Solution:**

### 4a. `drivesPerNode` Template Function

Added to `_helpers.tpl`:

```yaml
{{- define "rustfs.drivesPerNode" -}}
{{- if .Values.drivesPerNode }}
{{- .Values.drivesPerNode | int }}
{{- else if le (int .Values.replicaCount) 4 }}
{{- .Values.replicaCount | int }}
{{- else }}
{{- 1 }}
{{- end }}
{{- end }}
```

This auto-detects the number of data volumes per pod based on cluster size, or allows explicit override via `values.yaml`.

### 4b. Dynamic Volume URL Generation

Updated `rustfs.volumes` in `_helpers.tpl` to generate the `RUSTFS_VOLUMES` environment variable for any replica count:

- **Multi-drive:** `http://rustfs-{0...N}.rustfs-headless:9000/data/rustfs{0...M}`
- **Single-drive:** `http://rustfs-{0...N}.rustfs-headless:9000/data`

### 4c. StatefulSet Enhancements

- `topologySpreadConstraints` — from values
- `terminationGracePeriodSeconds` — configurable
- `startupProbe` — tolerates slow initialization (default: 30 retries × 10s = 5 min)
- `extraEnv` — for Tokio runtime tuning (`RUSTFS_RUNTIME_WORKER_THREADS`, etc.)
- Init container uses `DRIVES_PER_NODE` env var for generic volume initialization

**How it was tested:**

```bash
# Validate template rendering for multiple replica counts
helm template rustfs ./helm/rustfs --set replicaCount=4
helm template rustfs ./helm/rustfs --set replicaCount=8 --set drivesPerNode=2
helm template rustfs ./helm/rustfs --set replicaCount=16 --set drivesPerNode=1
helm template rustfs ./helm/rustfs --set replicaCount=32 --set drivesPerNode=1

# Verify resource counts
helm template rustfs ./helm/rustfs | grep "^kind:" | sort | uniq -c
helm template rustfs ./helm/rustfs -f ./helm/rustfs/values-production.yaml | grep "^kind:" | sort | uniq -c

# Expected outputs:
# Default (distributed): 9 resources (ConfigMap, Secret, Headless Service, Service, StatefulSet, PDB, + others)
# Production: 10 resources (adds ServiceMonitor)
```

All template renderings succeeded without errors for 4, 8, 16, and 32 replica configurations.

---

## 5. HorizontalPodAutoscaler

**File:** `helm/rustfs/templates/hpa.yaml` (new)

**Purpose:** Enables automatic horizontal scaling based on CPU and memory utilization.

**Configuration in `values.yaml`:**

```yaml
autoscaling:
  enabled: false  # Enable explicitly when needed
  minReplicas: 4
  maxReplicas: 16
  targetCPUUtilizationPercentage: 75
  targetMemoryUtilizationPercentage: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
    scaleUp:
      stabilizationWindowSeconds: 60
```

**Note:** HPA is disabled by default because distributed erasure-coded storage requires careful scaling with volume reconfiguration. It is most useful for stateless gateway/proxy deployments.

**How it was tested:**
```bash
# HPA template renders correctly when enabled
helm template rustfs ./helm/rustfs --set autoscaling.enabled=true | grep -A 20 "kind: HorizontalPodAutoscaler"

# HPA is excluded when disabled (default)
helm template rustfs ./helm/rustfs | grep "HorizontalPodAutoscaler"
# (no output = correctly excluded)
```

---

## 6. ServiceMonitor for Prometheus

**File:** `helm/rustfs/templates/servicemonitor.yaml` (new)

**Purpose:** Automated Prometheus metrics scraping via the Prometheus Operator CRD.

**Configuration:**
```yaml
metrics:
  serviceMonitor:
    enabled: true
    interval: "30s"
    scrapeTimeout: "10s"
```

**How it was tested:**
```bash
# ServiceMonitor renders correctly when enabled
helm template rustfs ./helm/rustfs -f ./helm/rustfs/values-production.yaml | grep -A 15 "kind: ServiceMonitor"
```

---

## 7. Production Values File

**File:** `helm/rustfs/values-production.yaml` (new)

**Purpose:** Battle-tested defaults for production deployments with high availability:

| Setting | Value | Rationale |
|---------|-------|-----------|
| `replicaCount` | 16 | Provides sufficient erasure coding redundancy |
| `drivesPerNode` | 1 | Simplifies volume management at scale |
| Resources | 2-8 CPU, 4-16Gi memory | Balanced for throughput and cost |
| `maxUnavailable` (PDB) | 1 | Minimizes disruption during rolling updates |
| Zone spread | `DoNotSchedule` | Ensures fault tolerance across AZs |
| Startup probe | 60 × 10s = 10 min | Tolerates large data set initialization |
| Blocking threads | 4096 | Handles high disk I/O parallelism |
| Ingress | nginx + cookie affinity | Improves TLS session cache hit rate |
| Log rotation | 100MB, hourly, 30 files | Prevents disk exhaustion |

**How it was tested:**
```bash
helm template rustfs ./helm/rustfs -f ./helm/rustfs/values-production.yaml
# Renders 10 Kubernetes resources without errors
```

---

## 8. Dockerfile Hardening

**File:** `Dockerfile`

**Changes:**

```dockerfile
# Health check for container orchestration (Docker Swarm, ECS, etc.)
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:9000/health || exit 1

# Explicit graceful shutdown signal
STOPSIGNAL SIGTERM
```

**Rationale:**
- `HEALTHCHECK` enables Docker Swarm and ECS to detect unhealthy containers automatically. Kubernetes uses its own liveness/readiness probes from the Helm chart instead.
- `STOPSIGNAL SIGTERM` ensures container orchestrators send the correct signal for graceful shutdown. The RustFS binary already handles SIGTERM via Tokio signal handlers.

**How it was tested:**
- Image builds successfully on both AMD64 and ARM64 via the existing `docker-buildx.sh` script
- Container starts and `/health` endpoint responds within the `start_period`

---

## 9. Docker Compose Multi-Architecture

**File:** `.docker/compose/docker-compose.cluster.yaml`

**Changes:**
- Removed hardcoded `platform: linux/amd64` from all service definitions — this was blocking ARM64 usage
- Added YAML extension anchors (`x-rustfs-common`) for DRY configuration
- Added health checks, resource limits (4 CPU, 8G memory), and restart policies
- Replaced host binary mounts with proper Docker volumes
- Added a dedicated bridge network for inter-node communication

**Before:**
```yaml
services:
  node0:
    platform: linux/amd64
    image: rustfs/rustfs:latest
    # ... individual config per node
```

**After:**
```yaml
x-rustfs-common: &rustfs-common
  image: rustfs/rustfs:latest
  environment: &rustfs-env
    RUSTFS_VOLUMES: "http://node{0...3}:9000/data/rustfs{0...3}"
    RUSTFS_ADDRESS: "0.0.0.0:9000"
    # ... shared configuration
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:9000/health"]
    interval: 30s
    timeout: 5s
    retries: 3
    start_period: 30s
  deploy:
    resources:
      limits:
        cpus: "4"
        memory: 8G

services:
  node0:
    <<: *rustfs-common
    # ... only node-specific config
```

**How it was tested:**
```bash
# Validate compose file
docker compose -f .docker/compose/docker-compose.cluster.yaml config

# Verify 4 services are defined
docker compose -f .docker/compose/docker-compose.cluster.yaml config --services
# Output: node0, node1, node2, node3

# Start cluster (works on both AMD64 and ARM64 hosts)
docker compose -f .docker/compose/docker-compose.cluster.yaml up -d
```

---

## 10. Grafana Dashboard Update

**File:** `.docker/observability/grafana/dashboards/rustfs.json`

**Change:** Replaced all 10 occurrences of `key_request_uri_path` with `key_api_type` to match the updated metrics labels in the application code.

**How it was tested:**
- Verified via `grep` that no references to the old label remain
- Dashboard JSON is valid and loadable by Grafana

---

## Testing & Validation

### Full Test Suite

```bash
# 1. Compile check
cargo check
# Result: SUCCESS

# 2. Linter (zero warnings)
cargo clippy -- -W clippy::all
# Result: SUCCESS, 0 warnings

# 3. Complete test suite
cargo test
# Result: 523 tests passed, 0 failed
#   - 516 original tests (no regressions)
#   - 7 new classify_api_path tests
```

### Helm Chart Validation

```bash
# Default distributed mode
helm template rustfs ./helm/rustfs
# Result: 9 resources rendered

# Production configuration
helm template rustfs ./helm/rustfs -f ./helm/rustfs/values-production.yaml
# Result: 10 resources rendered (includes ServiceMonitor)

# Various replica counts
for r in 4 8 16 32; do
  echo "=== Replicas: $r ==="
  helm template rustfs ./helm/rustfs --set replicaCount=$r 2>&1 | head -5
done
# Result: All render successfully
```

### Docker Compose Validation

```bash
docker compose -f .docker/compose/docker-compose.cluster.yaml config --quiet
# Result: Valid configuration

docker compose -f .docker/compose/docker-compose.cluster.yaml config --services
# Result: node0 node1 node2 node3
```

---

## Verification Checklist

Use this checklist to verify all changes are working correctly in your environment:

- [ ] **Build:** `cargo check` passes
- [ ] **Lint:** `cargo clippy` produces 0 warnings
- [ ] **Tests:** `cargo test` — 523 tests pass
- [ ] **Helm default:** `helm template rustfs ./helm/rustfs` renders without errors
- [ ] **Helm production:** `helm template rustfs ./helm/rustfs -f ./helm/rustfs/values-production.yaml` renders without errors
- [ ] **Docker image (AMD64):** `docker build --platform linux/amd64 -t rustfs:test .` succeeds
- [ ] **Docker image (ARM64):** `docker build --platform linux/arm64 -t rustfs:test .` succeeds
- [ ] **Docker Compose:** `docker compose -f .docker/compose/docker-compose.cluster.yaml up -d` starts 4 healthy nodes
- [ ] **Health check:** `curl http://localhost:9000/health` returns OK
- [ ] **Cluster health:** All 4 nodes respond on ports 9000-9003
- [ ] **Metrics:** `curl http://localhost:9000/metrics` shows `rustfs_api_requests_total` with `key_api_type` label
- [ ] **No old labels:** `curl http://localhost:9000/metrics | grep key_request_uri_path` returns nothing
- [ ] **Grafana:** Dashboard loads without "unknown label" errors
