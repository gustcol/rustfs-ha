# rust-ha: High-Availability Benchmark for RustFS

A comprehensive benchmark study comparing two high-availability approaches for [RustFS](https://github.com/rustfs/rustfs) — a high-performance, S3-compatible object storage system built in Rust.

This repository contains the full RustFS source code along with Docker Compose configurations, HAProxy load balancer setups, automated benchmarking scripts, and detailed results comparing **distributed erasure-coded clusters** vs **read-only replica scaling**.

## Why This Repository Exists

When deploying RustFS for read-heavy workloads (CDN-like access, static asset serving, data lake reads), there are two fundamentally different scaling strategies:

- **Approach A (Distributed Cluster):** Each node owns different erasure-coded data shards. Any node can serve any request by routing internally via gRPC. Provides full read/write capability with data redundancy.

- **Approach B (Read-Only Replicas):** One writer node ingests data into a shared volume. Multiple read-only replicas mount the same volume and serve reads directly from the local filesystem — no inter-node communication required.

This project benchmarks both approaches under identical conditions to determine which is better for read-dominated workloads.

## Key Results

**Approach B (Read-Only Replicas) is the clear winner for read workloads**, providing dramatically better performance across all metrics:

### Throughput (Requests/Second)

| Object Size | Concurrency | Distributed (A) | Read-Only (B) | Improvement |
|-------------|-------------|------------------|----------------|-------------|
| 1 KB        | 100         | 298 req/s        | **6,126 req/s**| **20.5x**   |
| 10 KB       | 100         | 282 req/s        | **5,292 req/s**| **18.8x**   |
| 100 KB      | 100         | 219 req/s        | **1,463 req/s**| **6.7x**    |
| 1 MB        | 100         | 58 req/s         | **158 req/s**  | **2.7x**    |

### Tail Latency (P99)

| Object Size | Concurrency | Distributed (A) | Read-Only (B) | Improvement |
|-------------|-------------|------------------|----------------|-------------|
| 1 KB        | 100         | 9,699 ms         | **54 ms**      | **179x**    |
| 10 KB       | 100         | 9,702 ms         | **59 ms**      | **165x**    |
| 100 KB      | 100         | 9,724 ms         | **240 ms**     | **40x**     |
| 1 MB        | 100         | 9,860 ms         | **1,868 ms**   | **5.3x**    |

### Error Rate

| Approach        | All Tests |
|-----------------|-----------|
| Distributed (A) | 0.04%–2.91% |
| Read-Only (B)   | **0%**       |

### With Cache Layer (Approach C)

Adding HAProxy's built-in HTTP cache on top of read-only replicas further improves small-object performance:

| Object Size | No Cache (B)  | HAProxy Cache (C) | Improvement |
|-------------|---------------|---------------------|-------------|
| 1 KB        | 6,126 req/s   | **23,915 req/s**    | **3.9x**    |
| 10 KB       | 5,292 req/s   | **13,386 req/s**    | **2.5x**    |
| 100 KB      | 1,463 req/s   | 1,543 req/s         | ~1.0x       |
| 1 MB        | 158 req/s     | 151 req/s           | ~1.0x       |

Cache eliminates the entire backend round-trip (auth, metadata, disk I/O) for hot objects. Diminishing returns above 100KB where network bandwidth becomes the bottleneck.

For the full analysis, see [Benchmark Comparison Report](.docker/compose/benchmark-results/COMPARISON.md) and [Cache Layer Analysis](.docker/compose/benchmark-results/CACHE-ANALYSIS.md).

## Architecture

### Approach A: Distributed Cluster

```
                    ┌─────────┐
    Clients ───────▶│ HAProxy │
                    └────┬────┘
            ┌────────┬───┴───┬────────┐
            ▼        ▼       ▼        ▼
        ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
        │Node 0│◄┤Node 1│◄┤Node 2│◄┤Node 3│
        │(EC)  │►│(EC)  │►│(EC)  │►│(EC)  │
        └──────┘ └──────┘ └──────┘ └──────┘
            ▲        ▲       ▲        ▲
            └────────┴───────┴────────┘
              gRPC inter-node traffic
```

- 4 erasure-coded nodes, each owning different data shards
- HAProxy round-robin across all nodes
- Any node can serve any request (routes internally)
- Full read/write capability

### Approach B: Read-Only Replicas

```
                    ┌─────────┐        ┌────────┐
    Clients ───────▶│ HAProxy │        │ Writer │
     (reads)        └────┬────┘        └───┬────┘
            ┌────────┬───┴───┬────────┐    │
            ▼        ▼       ▼        ▼    ▼
        ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
        │Rep 0 │ │Rep 1 │ │Rep 2 │ │Rep 3 │
        │ (RO) │ │ (RO) │ │ (RO) │ │ (RO) │
        └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘
           │        │        │        │
           └────────┴────┬───┴────────┘
                    ┌────┴────┐
                    │ Shared  │
                    │ Volume  │
                    └─────────┘
```

- 1 writer node for data ingestion
- 4 read-only replicas mounting the same volume
- Each replica reads directly from local filesystem
- No inter-node communication — pure local I/O

## Repository Structure

```
.
├── crates/                         # RustFS Rust workspace (35 crates)
│   ├── ecstore/                    # Erasure coding storage engine
│   ├── lock/                       # Distributed/local lock manager
│   └── ...                         # Other core crates
├── rustfs/                         # Main RustFS binary crate
├── helm/rustfs/                    # Kubernetes Helm chart
│   ├── templates/                  # StatefulSet, HPA, ServiceMonitor
│   ├── values.yaml                 # Default values (distributed mode)
│   └── values-production.yaml      # Production-ready configuration
├── .docker/compose/                # Docker Compose benchmark setup
│   ├── docker-compose.test-distributed.yaml  # Approach A config
│   ├── docker-compose.test-readonly.yaml     # Approach B config
│   ├── docker-compose.test-cached.yaml      # Approach C config (HAProxy cache)
│   ├── docker-compose.test-moka-cache.yaml  # Approach D config (moka cache)
│   ├── haproxy/                    # HAProxy configurations
│   │   ├── haproxy-distributed.cfg
│   │   ├── haproxy-readonly.cfg
│   │   └── haproxy-cached.cfg      # HAProxy with built-in HTTP cache
│   ├── benchmark.sh                # Automated benchmark script
│   ├── Dockerfile.local            # Local build with cache mounts
│   └── benchmark-results/          # Raw results and comparison
│       ├── COMPARISON.md           # Full analysis report (A vs B)
│       ├── CACHE-ANALYSIS.md       # Cache layer analysis (C vs D)
│       ├── approach-A.txt          # Distributed cluster results
│       ├── approach-A-resources.txt
│       ├── approach-B.txt          # Read-only replica results
│       └── approach-B-resources.txt
├── docs/
│   ├── SCALING.md                  # Comprehensive scaling guide
│   └── IMPLEMENTATION.md           # Implementation details
├── Dockerfile                      # Production multi-arch Dockerfile
├── docker-compose.yml              # Standard deployment
└── entrypoint.sh                   # Container entrypoint
```

## Quick Start

### Prerequisites

- Docker and Docker Compose
- `hey` HTTP load generator (`brew install hey` or `go install github.com/rakyll/hey@latest`)
- AWS CLI v2 (for S3 operations with SigV4 authentication)

### Build the Image

```bash
cd .docker/compose
docker build -t rustfs/rustfs:local -f Dockerfile.local ../..
```

### Run Approach A (Distributed Cluster)

```bash
docker compose -f .docker/compose/docker-compose.test-distributed.yaml up -d

# Wait for all nodes to be healthy (~2 minutes for peer discovery)
docker compose -f .docker/compose/docker-compose.test-distributed.yaml ps

# Create a test bucket
export AWS_ACCESS_KEY_ID=rustfsadmin
export AWS_SECRET_ACCESS_KEY=rustfsadmin
aws --endpoint-url http://localhost:8090 s3 mb s3://testbucket

# Upload test data
dd if=/dev/urandom bs=1024 count=1 | aws --endpoint-url http://localhost:8090 s3 cp - s3://testbucket/obj-1k

# Generate a presigned URL and benchmark
URL=$(aws --endpoint-url http://localhost:8090 s3 presign s3://testbucket/obj-1k --expires-in 3600)
hey -n 50000 -c 100 -z 10s "$URL"
```

### Run Approach B (Read-Only Replicas)

```bash
docker compose -f .docker/compose/docker-compose.test-readonly.yaml up -d

# Upload via writer node (port 8091)
export AWS_ACCESS_KEY_ID=rustfsadmin
export AWS_SECRET_ACCESS_KEY=rustfsadmin
aws --endpoint-url http://localhost:8091 s3 mb s3://testbucket
dd if=/dev/urandom bs=1024 count=1 | aws --endpoint-url http://localhost:8091 s3 cp - s3://testbucket/obj-1k

# Read via HAProxy (port 8090) — distributes across 4 replicas
URL=$(aws --endpoint-url http://localhost:8090 s3 presign s3://testbucket/obj-1k --expires-in 3600)
hey -n 50000 -c 100 -z 10s "$URL"
```

### Run the Full Benchmark Suite

```bash
cd .docker/compose
chmod +x benchmark.sh
./benchmark.sh
```

## Kubernetes Deployment

The included Helm chart supports both approaches:

### Distributed Mode (default)

```bash
helm install rustfs ./helm/rustfs \
  --set replicaCount=4

# Or with production values (16 replicas, zone-aware scheduling)
helm install rustfs ./helm/rustfs -f ./helm/rustfs/values-production.yaml
```

### Standalone Mode with External Read Replicas

```bash
# Deploy writer
helm install rustfs-writer ./helm/rustfs \
  --set replicaCount=1 \
  --set mode.standalone.enabled=true \
  --set mode.distributed.enabled=false

# Deploy read replicas sharing the same PVC
helm install rustfs-reader ./helm/rustfs \
  --set replicaCount=4 \
  --set mode.standalone.enabled=true \
  --set mode.distributed.enabled=false \
  --set mode.standalone.existingClaim.dataClaim=rustfs-writer-data
```

For full Kubernetes scaling documentation, see [docs/SCALING.md](docs/SCALING.md).

## When to Use Each Approach

| Criteria              | Distributed (A)                    | Read-Only Replicas (B)               |
|-----------------------|------------------------------------|--------------------------------------|
| **Best for**          | Read/write workloads               | Read-heavy workloads (>90% reads)    |
| **Data redundancy**   | Erasure coding across nodes        | Depends on shared volume durability  |
| **Write support**     | All nodes can write                | Only writer node                     |
| **Read throughput**   | Moderate (gRPC overhead)           | Excellent (local I/O)               |
| **Tail latency**      | High under load (~10s P99)         | Low (~50ms–1.8s P99)                |
| **Error rate**        | 0.04%–2.91%                        | 0%                                   |
| **Scalability**       | Add nodes for capacity + throughput| Add replicas for throughput only     |
| **Complexity**        | Higher (peer discovery, EC)        | Lower (shared volume mount)          |
| **Use case**          | General-purpose storage backend    | CDN, static assets, archives         |

## Test Configuration

- **Platform:** Apple Silicon (ARM64), Docker Desktop
- **Resources:** 2 CPU, 2GB RAM per node/replica
- **Load balancer:** HAProxy 2.9 (round-robin)
- **Benchmark tool:** `hey` HTTP load generator
- **Object sizes:** 1KB, 10KB, 100KB, 1MB
- **Concurrency levels:** 100, 500

## Based On

This project is built on [RustFS](https://github.com/rustfs/rustfs), a high-performance, S3-compatible object storage system written in Rust. Licensed under Apache 2.0.

## License

[Apache 2.0](LICENSE)
