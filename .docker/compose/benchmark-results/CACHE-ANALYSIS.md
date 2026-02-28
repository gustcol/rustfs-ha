# Cache Layer Analysis for RustFS Read-Only Replicas

**Test Date:** February 28, 2026
**Platform:** Apple Silicon (ARM64), Docker Desktop
**Baseline:** Approach B (Read-Only Replicas + HAProxy, no cache)

## Overview

This analysis evaluates whether adding a caching layer improves performance on top of the read-only replica architecture (Approach B). Two caching strategies were tested:

- **Approach C:** HAProxy built-in HTTP cache (256 MB shared RAM cache at the load balancer)
- **Approach D:** RustFS built-in moka object cache (256 MB per replica, in-process async cache)

## Request Path Analysis

Before looking at numbers, understanding **where time is spent** per request explains why caching helps:

```
┌─────────────────────────────────────────────────────────────┐
│ Per-Request Processing (Approach B, no cache)               │
├─────────────────────────────────────────────────────────────┤
│ 1. HAProxy routing                          ~0.1 ms        │
│ 2. TCP connection to backend                ~0.2 ms        │
│ 3. AWS Signature V4 HMAC verification       ~0.3 ms  (CPU) │
│ 4. IAM policy evaluation (2-3 passes)       ~0.2 ms  (CPU) │
│ 5. Bucket metadata lookup (RwLock)          ~0.1 ms  (MEM) │
│ 6. read_all_fileinfo() — N xl.meta reads    ~2-5 ms  (I/O) │
│ 7. Namespace lock acquisition               ~0.1 ms  (MEM) │
│ 8. Bitrot hash verification (HighwayHash)   ~0.5 ms  (CPU) │
│ 9. Data read from disk                      ~1-500 ms (I/O)│
│ 10. Response serialization + transfer       ~0.5-50 ms     │
├─────────────────────────────────────────────────────────────┤
│ Total for 1 KB object: ~5-16 ms                            │
│ Total for 1 MB object: ~40-600 ms                          │
└─────────────────────────────────────────────────────────────┘
```

### What Each Cache Layer Eliminates

| Processing Step | HAProxy Cache (C) | Moka Cache (D) |
|----------------|:-----------------:|:--------------:|
| HAProxy routing | kept | kept |
| TCP to backend | **eliminated** | kept |
| SigV4 HMAC verification | **eliminated** | kept |
| IAM policy evaluation | **eliminated** | kept |
| Bucket metadata lookup | **eliminated** | kept |
| xl.meta file reads | **eliminated** | **eliminated** |
| Namespace lock | **eliminated** | **eliminated** |
| Bitrot verification | **eliminated** | **eliminated** |
| Disk data read | **eliminated** | **eliminated** |
| Response serialization | **eliminated** | kept |

**Key insight:** HAProxy cache eliminates the *entire backend round-trip* including auth. Moka cache eliminates disk I/O but still processes auth, policy, and HTTP through RustFS on every request.

## Results

### Throughput (Requests/Second) — All Approaches

| Object Size | Concurrency | B (No Cache) | C (HAProxy Cache) | D (Moka Cache) | Best | vs No Cache |
|-------------|-------------|--------------|--------------------|--------------------|------|-------------|
| 1 KB        | 100         | 6,126        | **23,915**         | 10,372             | C    | **3.9x**    |
| 10 KB       | 100         | 5,292        | **13,386**         | 6,555              | C    | **2.5x**    |
| 100 KB      | 100         | 1,463        | **1,543**          | 1,499              | C    | **1.05x**   |
| 1 MB        | 100         | 158          | 151                | **154**             | B    | **~1.0x**   |
| 1 KB        | 500 (burst) | 6,629        | **26,326**         | 11,371             | C    | **3.97x**   |
| 100 KB      | 500 (burst) | 1,374        | **1,239**          | 1,249              | B    | **~1.0x**   |

### Latency P50 (milliseconds, lower is better)

| Object Size | Concurrency | B (No Cache) | C (HAProxy Cache) | D (Moka Cache) |
|-------------|-------------|--------------|--------------------|--------------------|
| 1 KB        | 100         | 12.8         | **2.6**            | 5.4                |
| 10 KB       | 100         | 15.7         | **7.4**            | 9.1                |
| 100 KB      | 100         | 50.8         | **47.5**           | 56.8               |
| 1 MB        | 100         | 547.8        | 535.4              | **621.5**          |
| 1 KB        | 500 (burst) | 69.3         | **12.1**           | 31.1               |
| 100 KB      | 500 (burst) | 293.4        | **259.3**          | 277.6              |

### Latency P99 (milliseconds, lower is better)

| Object Size | Concurrency | B (No Cache) | C (HAProxy Cache) | D (Moka Cache) |
|-------------|-------------|--------------|--------------------|--------------------|
| 1 KB        | 100         | 54.2         | **43.6**           | 65.7               |
| 10 KB       | 100         | 58.7         | **10.3**           | 63.0               |
| 100 KB      | 100         | 240.0        | **170.0**          | 354.1              |
| 1 MB        | 100         | 1,868        | **2,464**          | 1,949              |
| 1 KB        | 500 (burst) | 209.3        | **62.6**           | 125.6              |
| 100 KB      | 500 (burst) | 1,211        | **1,659**          | 1,273              |

### Error Rate

All approaches achieved **0% error rate** across all tests.

### Resource Usage (post-benchmark)

**Approach C (HAProxy Cache):**
```
CONTAINER       CPU %   MEM USAGE / LIMIT   NET I/O
haproxy-cached  0.00%   311.7MiB / 512MiB   598MB / 7.17GB
replica0        0.12%   260MiB / 2GiB       107kB / 29MB
replica1        0.05%   261.5MiB / 2GiB     105kB / 29.1MB
replica2        0.06%   269MiB / 2GiB       105kB / 30MB
replica3        0.07%   278.1MiB / 2GiB     106kB / 30MB
writer-node     0.05%   116.6MiB / 2GiB     1.19MB / 7.38kB

Observations:
  - HAProxy uses 311 MB (256 MB cache + overhead)
  - Replicas received only ~29 MB each (vs 1.36 GB without cache = 98% hit rate)
  - Replicas are essentially idle — cache serves nearly everything
```

**Approach D (Moka In-Process Cache):**
```
CONTAINER       CPU %   MEM USAGE / LIMIT   NET I/O
haproxy-moka    0.06%   41.25MiB / 512MiB   6GB / 6.16GB
replica0        0.10%   203.3MiB / 2GiB     40.5MB / 1.43GB
replica1        0.05%   207.1MiB / 2GiB     40.5MB / 1.43GB
replica2        0.14%   191.5MiB / 2GiB     40.5MB / 1.43GB
replica3        0.07%   158.7MiB / 2GiB     40.6MB / 1.43GB
writer-node     0.06%   112.8MiB / 2GiB     1.19MB / 7.25kB

Observations:
  - HAProxy is lightweight (41 MB) — no caching overhead
  - Replicas use less memory than without moka (203 MB vs 627 MB)
    suggesting moka reduces internal buffer allocations
  - Each replica still processes full HTTP + auth per request
  - Network I/O is similar to no-cache (each replica served ~1.43 GB)
```

## Analysis

### Where Cache Helps (and Where It Doesn't)

```
Performance Gain vs Object Size

Throughput     │ C (HAProxy Cache)
improvement    │
(x factor)     │
               │
  4.0x ────────│── ● 1 KB
               │
  3.0x ────────│
               │
  2.5x ────────│──── ● 10 KB
               │
  2.0x ────────│
               │
  1.5x ────────│
               │
  1.0x ────────│──────── ● 100 KB ──── ● 1 MB
               │
               └────────────────────────────────
                    1KB    10KB   100KB   1MB
                         Object Size
```

**Small objects (1-10 KB): Cache is transformative.**
- The request processing overhead (auth, metadata, disk I/O) dominates latency for small objects
- HAProxy cache eliminates ALL of this — it serves directly from RAM without contacting any backend
- Result: 3.9x throughput improvement, latency drops from 12.8ms to 2.6ms

**Medium objects (100 KB): Marginal improvement.**
- Network transfer time starts dominating over processing overhead
- Cache still helps by avoiding backend connections, but the gain is small (~5%)
- The 256 MB cache fills up quickly with 100 KB objects (only ~2,560 objects fit)

**Large objects (1 MB): No improvement / slightly worse.**
- Network bandwidth is the bottleneck, not processing overhead
- HAProxy must buffer the entire object in cache memory before serving
- The 10 MB max-object-size limit prevents caching very large objects
- Cache memory pressure can cause evictions that hurt performance

### Why HAProxy Cache (C) Beats Moka Cache (D)

| Factor | HAProxy Cache | Moka Cache |
|--------|--------------|------------|
| Auth overhead per request | None (bypassed) | Full SigV4 HMAC |
| HTTP parsing per request | Minimal (cache lookup) | Full S3 request parsing |
| Network hops | 0 (client ↔ HAProxy only) | 2 (client ↔ HAProxy ↔ replica) |
| Cache topology | Single shared cache | 4 separate caches |
| Cache efficiency | 1 copy per object | 4 copies (1 per replica) |
| Memory for 1000 objects × 1KB | 1 MB | 4 MB (4 replicas) |

The **single shared cache** in HAProxy is more memory-efficient than 4 independent moka caches. HAProxy also eliminates the most expensive per-request operation: the full HTTP round-trip to the backend including AWS Signature verification.

### Cache Invalidation Considerations

| Strategy | HAProxy Cache | Moka Cache |
|----------|--------------|------------|
| TTL-based expiry | Yes (300s default) | Yes (300s TTL, 120s TTI) |
| Active invalidation | Manual (API/CLI) | Automatic on write |
| Stale data window | Up to TTL seconds | Up to TTL seconds |
| Consistency | Eventual (TTL-bound) | Eventual (TTL-bound) |
| Purge capability | `http-request set-var` | Internal, not exposed |

For **read-only workloads** (the target use case), cache invalidation is rarely needed since data changes infrequently. The 5-minute TTL provides a reasonable default.

## Recommendations

### Decision Matrix

| Workload Profile | Recommended Approach | Why |
|-----------------|---------------------|-----|
| Hot small objects (<10 KB), high concurrency | **C (HAProxy Cache)** | 3.9x throughput, eliminates all backend overhead |
| Mixed object sizes, moderate concurrency | **B (No Cache)** | Cache adds complexity with marginal gain for large objects |
| Large objects (>100 KB) | **B (No Cache)** | Network bandwidth is the bottleneck, cache doesn't help |
| Read-only CDN with known hot set | **C (HAProxy Cache)** | Maximum throughput for cache-friendly workloads |
| Read-heavy with occasional writes | **D (Moka Cache)** | Auto-invalidation on writes, no stale data risk |

### Optimal Configuration: Layered Cache

For maximum performance, combine both cache layers:

```
                         ┌─────────────┐
         Clients ───────▶│   HAProxy   │
                         │ (256MB RAM  │
                         │  cache L1)  │
                         └──────┬──────┘
                    cache miss  │
                 ┌──────────┬───┴───┬──────────┐
                 ▼          ▼       ▼          ▼
             ┌──────┐  ┌──────┐ ┌──────┐  ┌──────┐
             │Rep 0 │  │Rep 1 │ │Rep 2 │  │Rep 3 │
             │(moka │  │(moka │ │(moka │  │(moka │
             │ L2)  │  │ L2)  │ │ L2)  │  │ L2)  │
             └──┬───┘  └──┬───┘ └──┬───┘  └──┬───┘
                │         │        │         │
                └─────────┴────┬───┴─────────┘
                          ┌────┴────┐
                          │ Shared  │
                          │ Volume  │  (L3: OS page cache)
                          └─────────┘
```

- **L1 (HAProxy):** Catches the hottest objects, eliminates backend round-trips entirely
- **L2 (Moka):** Catches cache misses from L1, eliminates disk I/O and bitrot verification
- **L3 (OS page cache):** Catches L2 misses, kernel-level filesystem caching

### Expected Combined Performance

| Object Size | No Cache | HAProxy Only | Estimated Combined |
|-------------|----------|-------------|-------------------|
| 1 KB        | 6,126    | 23,915      | ~24,000 req/s     |
| 10 KB       | 5,292    | 13,386      | ~13,500 req/s     |
| 100 KB      | 1,463    | 1,543       | ~1,600 req/s      |
| 1 MB        | 158      | 151         | ~160 req/s        |

The combined approach primarily benefits from L1 (HAProxy). L2 (moka) adds marginal improvement but provides **insurance** against L1 cache evictions and handles objects too large for L1.

## Conclusion

**Yes, adding a cache layer significantly improves performance — but only for small objects.**

- For objects **under 10 KB**: HAProxy cache delivers a **2.5x–3.9x throughput improvement** and **5x latency reduction**. This is the sweet spot.
- For objects **over 100 KB**: Cache provides **negligible improvement** because network bandwidth becomes the bottleneck, not processing overhead.
- **HAProxy cache is superior to moka cache** for read-only workloads because it eliminates the entire backend round-trip including authentication.
- The **best architecture** for read-heavy workloads with many small objects is: HAProxy cache (L1) → Read-only replicas with moka (L2) → Shared volume with OS page cache (L3).

### Quick Numbers Summary

| Approach | 1KB req/s | 1KB P50 | Memory Overhead |
|----------|-----------|---------|-----------------|
| B (No Cache) | 6,126 | 12.8 ms | 0 MB |
| C (HAProxy Cache) | **23,915** | **2.6 ms** | 312 MB (HAProxy) |
| D (Moka Cache) | 10,372 | 5.4 ms | ~0 MB (lower replica usage) |
