# RustFS Scaling Guide

This guide covers deploying RustFS at scale on Kubernetes, supporting millions of concurrent connections across multi-architecture clusters (AMD64 and ARM64).

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Multi-Architecture Support](#multi-architecture-support)
- [Kubernetes Deployment](#kubernetes-deployment)
  - [Standalone Mode](#standalone-mode)
  - [Distributed Mode](#distributed-mode)
  - [Production Configuration](#production-configuration)
- [Scaling Strategies](#scaling-strategies)
  - [Horizontal Scaling](#horizontal-scaling)
  - [Vertical Scaling](#vertical-scaling)
  - [Zone-Aware Scheduling](#zone-aware-scheduling)
- [Performance Tuning](#performance-tuning)
  - [Tokio Runtime](#tokio-runtime)
  - [Network Stack](#network-stack)
  - [Kernel Parameters](#kernel-parameters)
  - [TLS Optimization](#tls-optimization)
- [Monitoring & Observability](#monitoring--observability)
- [Docker Compose Cluster](#docker-compose-cluster)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

RustFS is a distributed, erasure-coded object storage system built in Rust. Its scaling architecture follows these principles:

```
                        ┌─────────────────────────────┐
                        │        Load Balancer         │
                        │   (Ingress / NodePort / LB)  │
                        └─────────────┬───────────────┘
                                      │
          ┌───────────────────────────┼───────────────────────────┐
          │                           │                           │
   ┌──────▼──────┐            ┌──────▼──────┐            ┌──────▼──────┐
   │  rustfs-0   │◄──────────►│  rustfs-1   │◄──────────►│  rustfs-N   │
   │  (Pod)      │   gRPC     │  (Pod)      │   gRPC     │  (Pod)      │
   │             │   P2P      │             │   P2P      │             │
   ├─────────────┤            ├─────────────┤            ├─────────────┤
   │  PVC: data  │            │  PVC: data  │            │  PVC: data  │
   │  PVC: logs  │            │  PVC: logs  │            │  PVC: logs  │
   └─────────────┘            └─────────────┘            └─────────────┘
```

**Key Properties:**
- **Stateless API Layer**: S3 API requests can be routed to any node
- **Peer-to-Peer Data Layer**: Nodes discover each other via DNS (headless service)
- **Erasure Coding**: Data is sharded across nodes with configurable redundancy
- **Lock-Free State**: Atomic state management avoids contention at scale

## Multi-Architecture Support

RustFS ships multi-architecture Docker images supporting both **AMD64** (x86_64) and **ARM64** (aarch64):

```bash
# The same image works on both architectures
docker pull rustfs/rustfs:latest

# For explicit platform selection
docker pull --platform linux/amd64 rustfs/rustfs:latest
docker pull --platform linux/arm64 rustfs/rustfs:latest
```

### Build Multi-Arch Images

```bash
# Build for both architectures
./docker-buildx.sh --push

# Build for a specific architecture
./docker-buildx.sh --platforms linux/arm64 --push

# Build a specific version
./docker-buildx.sh --release v1.0.0 --push
```

### CI/CD Multi-Arch Pipeline

The GitHub Actions workflow (`.github/workflows/docker.yml`) automatically:
1. Sets up QEMU for cross-platform emulation
2. Uses Docker Buildx with multi-platform support
3. Publishes manifest lists covering `linux/amd64,linux/arm64`

## Kubernetes Deployment

### Prerequisites

- Kubernetes 1.26+
- Helm 3.x
- A StorageClass with dynamic provisioning
- 4+ nodes for distributed mode (recommended across multiple zones)

### Standalone Mode

Single-node deployment for development/testing:

```bash
helm install rustfs ./helm/rustfs \
  --set mode.standalone.enabled=true \
  --set mode.distributed.enabled=false
```

### Distributed Mode

Multi-node deployment with erasure coding:

```bash
# 4 nodes, 4 drives each (default)
helm install rustfs ./helm/rustfs

# 8 nodes, 2 drives each
helm install rustfs ./helm/rustfs \
  --set replicaCount=8 \
  --set drivesPerNode=2

# 16 nodes, 1 drive each
helm install rustfs ./helm/rustfs \
  --set replicaCount=16 \
  --set drivesPerNode=1

# 32 nodes for large-scale deployment
helm install rustfs ./helm/rustfs \
  --set replicaCount=32 \
  --set drivesPerNode=1 \
  --set storageclass.dataStorageSize=1Ti
```

### Understanding `drivesPerNode`

| replicaCount | drivesPerNode | Data PVCs per Pod | Volume Pattern |
|---|---|---|---|
| 4 | 4 | 4 (`/data/rustfs0-3`) | Each pod manages 4 shards |
| 8 | 2 | 2 (`/data/rustfs0-1`) | Each pod manages 2 shards |
| 16 | 1 | 1 (`/data`) | Each pod manages 1 shard |
| 32 | 1 | 1 (`/data`) | Each pod manages 1 shard |

### Production Configuration

Use the production values file for high-availability deployments:

```bash
helm install rustfs ./helm/rustfs -f ./helm/rustfs/values-production.yaml
```

This configures:
- **16 replicas** across availability zones
- **Resource limits**: 2-8 CPU, 4-16Gi memory per pod
- **PodDisruptionBudget**: max 1 unavailable
- **TopologySpreadConstraints**: even distribution across zones
- **Startup probes**: 5-minute tolerance for slow starts
- **ServiceMonitor**: Prometheus metrics scraping
- **Log rotation**: 100MB files, hourly rotation, 30 file retention

## Scaling Strategies

### Horizontal Scaling

#### Manual Scaling (Recommended for Distributed Storage)

For distributed storage, scaling requires updating the peer discovery configuration:

```bash
# Scale from 4 to 8 replicas
helm upgrade rustfs ./helm/rustfs \
  --set replicaCount=8 \
  --set drivesPerNode=1
```

> **Important**: After scaling, existing data may need rebalancing. The self-healing mechanism (scanner/heal crates) handles this automatically over time.

#### HPA (Horizontal Pod Autoscaler)

HPA can be enabled for automatic scaling:

```yaml
autoscaling:
  enabled: true
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

> **Note**: HPA is most useful for gateway/proxy deployments. For distributed erasure-coded storage, manual scaling with volume reconfiguration is recommended.

### Vertical Scaling

Increase resources per pod for higher throughput:

```yaml
resources:
  requests:
    cpu: "4"
    memory: 8Gi
  limits:
    cpu: "16"
    memory: 32Gi
```

### Zone-Aware Scheduling

Distribute pods across availability zones for fault tolerance:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: rustfs

affinity:
  podAntiAffinity:
    enabled: true
    topologyKey: kubernetes.io/hostname
```

This ensures:
- No two pods on the same node (anti-affinity)
- Pods evenly distributed across zones (topology spread)
- Tolerates the failure of an entire availability zone

## Performance Tuning

### Tokio Runtime

The async runtime adapts to the system automatically, but can be tuned via environment variables:

```yaml
extraEnv:
  # Worker threads: defaults to physical CPU cores
  - name: RUSTFS_RUNTIME_WORKER_THREADS
    value: "0"  # 0 = auto-detect

  # Blocking thread pool: for disk I/O operations
  - name: RUSTFS_RUNTIME_MAX_BLOCKING_THREADS
    value: "4096"

  # Thread stack size
  - name: RUSTFS_RUNTIME_THREAD_STACK_SIZE
    value: "1048576"  # 1MiB
```

### Network Stack

RustFS automatically configures optimal network parameters:

| Parameter | Value | Purpose |
|---|---|---|
| TCP_NODELAY | Enabled | Low-latency small requests |
| SO_REUSEPORT | Enabled | Kernel-level load balancing across cores |
| TCP KeepAlive | 60s interval, 5s probe, 3 retries | Detect dead clients |
| Send/Recv buffers | 4MB each | Support GB/s throughput |
| TCP QuickAck | Enabled (Linux) | Faster ACK delivery |
| HTTP/2 stream window | 4MB | Large file throughput |
| HTTP/2 conn window | 8MB | Aggregate flow control |
| HTTP/2 max streams | 2,048 | High concurrency |
| HTTP/2 max frame | 512KB | Reduce framing overhead |

### Kernel Parameters

For nodes handling >100K concurrent connections, tune the kernel:

```bash
# Maximum file descriptors
ulimit -n 1048576

# TCP connection backlog
sysctl -w net.core.somaxconn=65535

# TCP TIME_WAIT optimization
sysctl -w net.ipv4.tcp_tw_reuse=1

# TCP buffer sizes (auto-tuned, these set the maximums)
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216

# Increase port range for outgoing connections
sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# TCP SYN backlog for handling bursts
sysctl -w net.ipv4.tcp_max_syn_backlog=65535

# Maximum number of connections tracked
sysctl -w net.netfilter.nf_conntrack_max=1048576
```

For Kubernetes DaemonSet-based sysctl tuning, use an init container or a privileged DaemonSet.

### TLS Optimization

TLS session caching reduces handshake overhead for returning clients:

- **Session cache**: 10,000 sessions in memory (~10MB)
- **ALPN**: `h2 > http/1.1 > http/1.0` priority
- **Session resumption**: Enabled by default
- **SNI**: Multi-certificate resolution supported

For sticky load balancing to improve TLS cache hit rate:

```yaml
ingress:
  nginxAnnotations:
    nginx.ingress.kubernetes.io/affinity: cookie
    nginx.ingress.kubernetes.io/session-cookie-name: rustfs
```

## Monitoring & Observability

### Prometheus ServiceMonitor

Enable automatic metrics collection:

```yaml
metrics:
  serviceMonitor:
    enabled: true
    interval: "30s"
    scrapeTimeout: "10s"
```

### Key Metrics

| Metric | Type | Description |
|---|---|---|
| `rustfs_api_requests_total` | Counter | Requests by method and API type |
| `rustfs_api_responses_total` | Counter | Responses by status class (2xx/3xx/4xx/5xx) |
| `rustfs_api_requests_failure_total` | Counter | Failed requests |
| `rustfs_request_latency_ms` | Histogram | Request latency distribution |
| `rustfs_request_body_len` | Histogram | Response body size distribution |
| `rustfs_tls_handshake_failures` | Counter | TLS handshake failures by type |
| `rustfs_cluster_*` | Gauge | Cluster capacity, usage, objects, buckets |
| `rustfs_node_*` | Gauge | Per-node disk metrics |

### Grafana Dashboard

A pre-configured Grafana dashboard is included at:
`.docker/observability/grafana/dashboards/rustfs.json`

Deploy with the observability stack:

```bash
docker compose -f .docker/compose/docker-compose.observability.yaml up -d
```

### Alerting Recommendations

```yaml
# High error rate
- alert: RustFSHighErrorRate
  expr: rate(rustfs_api_responses_total{key_status_class="5xx"}[5m]) > 0.01
  for: 5m

# High latency
- alert: RustFSHighLatency
  expr: histogram_quantile(0.99, rate(rustfs_request_latency_ms_bucket[5m])) > 5000
  for: 10m

# Pod not ready
- alert: RustFSPodNotReady
  expr: kube_pod_status_ready{pod=~".*rustfs.*"} == 0
  for: 5m
```

## Docker Compose Cluster

For local development and testing with multiple containers:

```bash
# Start a 4-node cluster (works on both AMD64 and ARM64)
docker compose -f .docker/compose/docker-compose.cluster.yaml up -d

# Check cluster health
for i in 0 1 2 3; do
  echo "Node $i:" && curl -s http://localhost:900$i/health | head -1
done

# Scale observation (each node discovers peers via DNS)
docker compose -f .docker/compose/docker-compose.cluster.yaml logs node0 | grep "peer"
```

### With Observability Stack

```bash
docker compose \
  -f .docker/compose/docker-compose.cluster.yaml \
  -f .docker/compose/docker-compose.observability.yaml \
  up -d
```

## Troubleshooting

### Pod Stuck in Pending

```bash
# Check node resources
kubectl describe pod <pod-name>
kubectl get events --sort-by='.lastTimestamp'

# Common causes:
# - Insufficient CPU/memory on nodes
# - PVC cannot be provisioned (StorageClass issue)
# - Anti-affinity prevents scheduling (not enough nodes)
```

### Pods CrashLooping

```bash
# Check startup probe configuration
kubectl logs <pod-name> --previous

# Increase startup probe tolerance for large data sets
helm upgrade rustfs ./helm/rustfs \
  --set startupProbe.failureThreshold=60 \
  --set startupProbe.periodSeconds=10
```

### Peer Discovery Failures

```bash
# Verify headless service DNS resolution
kubectl run -it --rm debug --image=busybox -- nslookup rustfs-headless

# Check RUSTFS_VOLUMES environment variable
kubectl exec rustfs-0 -- env | grep RUSTFS_VOLUMES

# Verify all pods have stable network identities
kubectl get pods -l app.kubernetes.io/name=rustfs -o wide
```

### High Memory Usage

```bash
# Check per-pod memory consumption
kubectl top pods -l app.kubernetes.io/name=rustfs

# Reduce connection buffers if memory-constrained
# (trade-off: lower throughput per connection)
extraEnv:
  - name: RUSTFS_RUNTIME_MAX_BLOCKING_THREADS
    value: "512"
```

### Performance Degradation

```bash
# Check disk I/O
kubectl exec rustfs-0 -- iostat -x 1 5

# Check network metrics
kubectl exec rustfs-0 -- ss -s

# Verify erasure coding quorum
curl http://rustfs-svc:9000/minio/health/cluster
```
