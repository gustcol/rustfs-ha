#!/bin/bash
# Benchmark script for comparing HAProxy approaches A (distributed) vs B (read-only replicas)
# Usage: ./benchmark.sh [distributed|readonly|both]

set -e

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$COMPOSE_DIR/benchmark-results"
mkdir -p "$RESULTS_DIR"

ACCESS_KEY="rustfsadmin"
SECRET_KEY="rustfsadmin"
HAPROXY_URL="http://localhost:8090"
WRITER_URL="http://localhost:8091"  # only for Approach B
BUCKET="testbucket"
TEST_SIZES="1k 10k 100k 1M"
CONCURRENCY_LEVELS="10 50 100 200"
DURATION="10s"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"; }
err() { echo -e "${RED}[$(date +%H:%M:%S)]${NC} $1"; }

wait_for_healthy() {
    local url="$1"
    local name="$2"
    local max_wait=120
    local elapsed=0
    log "Waiting for $name to be healthy at $url/health..."
    while [ $elapsed -lt $max_wait ]; do
        if curl -sf "$url/health" > /dev/null 2>&1; then
            log "$name is healthy!"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    err "$name failed to become healthy after ${max_wait}s"
    return 1
}

create_bucket() {
    local url="$1"
    local name="$2"
    log "Creating bucket '$BUCKET' on $name..."
    curl -sf -X PUT "$url/$BUCKET" \
        -u "$ACCESS_KEY:$SECRET_KEY" \
        -o /dev/null -w "%{http_code}" 2>/dev/null || true
    log "Bucket created on $name"
}

upload_test_data() {
    local url="$1"
    local name="$2"
    log "Uploading test objects to $name..."

    for size in $TEST_SIZES; do
        # Generate test file
        local bytes
        case $size in
            1k) bytes=1024 ;;
            10k) bytes=10240 ;;
            100k) bytes=102400 ;;
            1M) bytes=1048576 ;;
        esac

        local tmpfile=$(mktemp)
        dd if=/dev/urandom of="$tmpfile" bs=$bytes count=1 2>/dev/null

        # Upload multiple copies
        for i in $(seq 1 20); do
            curl -sf -X PUT "$url/$BUCKET/obj-${size}-${i}" \
                -u "$ACCESS_KEY:$SECRET_KEY" \
                -T "$tmpfile" \
                -o /dev/null 2>/dev/null &
        done
        wait

        rm -f "$tmpfile"
        log "  Uploaded 20 x $size objects"
    done
    log "Test data upload complete"
}

run_hey_benchmark() {
    local url="$1"
    local label="$2"
    local object="$3"
    local concurrency="$4"
    local outfile="$5"

    hey -z "$DURATION" -c "$concurrency" \
        -H "Authorization: Basic $(echo -n "$ACCESS_KEY:$SECRET_KEY" | base64)" \
        "$url/$BUCKET/$object" 2>&1 | tee -a "$outfile"
}

run_wrk_benchmark() {
    local url="$1"
    local label="$2"
    local object="$3"
    local concurrency="$4"
    local outfile="$5"

    wrk -t4 -c"$concurrency" -d"$DURATION" \
        -H "Authorization: Basic $(echo -n "$ACCESS_KEY:$SECRET_KEY" | base64)" \
        "$url/$BUCKET/$object" 2>&1 | tee -a "$outfile"
}

benchmark_approach() {
    local label="$1"
    local outfile="$RESULTS_DIR/${label}-results.txt"
    echo "=============================================" > "$outfile"
    echo " BENCHMARK: $label" >> "$outfile"
    echo " Date: $(date)" >> "$outfile"
    echo "=============================================" >> "$outfile"
    echo "" >> "$outfile"

    log "===== Benchmarking: $label ====="

    # Health check
    log "Health check: $(curl -sf "$HAPROXY_URL/health" 2>/dev/null || echo "FAIL")"

    # HAProxy stats
    log "HAProxy stats: http://localhost:8404/stats"

    for size in $TEST_SIZES; do
        for conc in $CONCURRENCY_LEVELS; do
            echo "" >> "$outfile"
            echo "--- GET obj-${size}-1 | concurrency=$conc ---" >> "$outfile"
            log "  Testing GET $size object with $conc concurrent connections..."

            # Use hey for structured output
            run_hey_benchmark "$HAPROXY_URL" "$label" "obj-${size}-1" "$conc" "$outfile"
            echo "" >> "$outfile"
        done
    done

    # High-concurrency burst test
    echo "" >> "$outfile"
    echo "--- BURST TEST: 500 concurrent, 100k objects ---" >> "$outfile"
    log "  Running burst test: 500 concurrent connections..."
    run_hey_benchmark "$HAPROXY_URL" "$label" "obj-100k-1" 500 "$outfile"

    # List objects test (S3 ListObjects)
    echo "" >> "$outfile"
    echo "--- LIST OBJECTS | concurrency=100 ---" >> "$outfile"
    log "  Testing LIST objects with 100 concurrent connections..."
    hey -z "$DURATION" -c 100 \
        -H "Authorization: Basic $(echo -n "$ACCESS_KEY:$SECRET_KEY" | base64)" \
        "$HAPROXY_URL/$BUCKET?list-type=2&max-keys=100" 2>&1 | tee -a "$outfile"

    # HEAD object test (metadata only)
    echo "" >> "$outfile"
    echo "--- HEAD obj-1k-1 | concurrency=100 ---" >> "$outfile"
    log "  Testing HEAD object with 100 concurrent connections..."
    hey -z "$DURATION" -c 100 -m HEAD \
        -H "Authorization: Basic $(echo -n "$ACCESS_KEY:$SECRET_KEY" | base64)" \
        "$HAPROXY_URL/$BUCKET/obj-1k-1" 2>&1 | tee -a "$outfile"

    log "===== $label benchmark complete ====="
    log "Results saved to: $outfile"
}

cleanup_approach() {
    local compose_file="$1"
    log "Cleaning up $compose_file..."
    docker compose -f "$compose_file" down -v --remove-orphans 2>/dev/null || true
}

test_distributed() {
    local compose_file="$COMPOSE_DIR/docker-compose.test-distributed.yaml"

    log "=========================================="
    log " APPROACH A: Distributed Cluster + HAProxy"
    log "=========================================="

    cleanup_approach "$compose_file"

    log "Starting distributed cluster..."
    docker compose -f "$compose_file" up -d

    wait_for_healthy "$HAPROXY_URL" "HAProxy (distributed)"

    create_bucket "$HAPROXY_URL" "distributed cluster"
    upload_test_data "$HAPROXY_URL" "distributed cluster"

    sleep 3  # let data settle

    benchmark_approach "approach-A-distributed"

    # Capture resource usage
    log "Resource usage during test:"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" \
        node0-dist node1-dist node2-dist node3-dist haproxy-distributed 2>/dev/null \
        | tee "$RESULTS_DIR/approach-A-resources.txt"

    cleanup_approach "$compose_file"
}

test_readonly() {
    local compose_file="$COMPOSE_DIR/docker-compose.test-readonly.yaml"

    log "=========================================="
    log " APPROACH B: Read-Only Replicas + HAProxy"
    log "=========================================="

    cleanup_approach "$compose_file"

    log "Starting read-only replica cluster..."
    docker compose -f "$compose_file" up -d

    # Wait for writer first
    wait_for_healthy "$WRITER_URL" "Writer node"

    # Create bucket and upload via writer
    create_bucket "$WRITER_URL" "writer node"
    upload_test_data "$WRITER_URL" "writer node"

    sleep 5  # let filesystem sync

    wait_for_healthy "$HAPROXY_URL" "HAProxy (readonly)"

    benchmark_approach "approach-B-readonly"

    # Capture resource usage
    log "Resource usage during test:"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" \
        replica0 replica1 replica2 replica3 writer-node haproxy-readonly 2>/dev/null \
        | tee "$RESULTS_DIR/approach-B-resources.txt"

    cleanup_approach "$compose_file"
}

generate_comparison() {
    local outfile="$RESULTS_DIR/COMPARISON.md"
    log "Generating comparison report..."

    cat > "$outfile" << 'HEADER'
# HAProxy Load Balancing Benchmark Comparison

## Approach A: Distributed Cluster
- 4 erasure-coded RustFS nodes
- Each node owns different data shards
- Any node can serve any S3 request (routes internally)
- HAProxy round-robin across all 4 nodes

## Approach B: Read-Only Replicas
- 1 writer node for data ingestion
- 4 read-only replicas sharing same Docker volume
- Each replica reads directly from local filesystem
- HAProxy round-robin across 4 read replicas

## Results

HEADER

    if [ -f "$RESULTS_DIR/approach-A-distributed-results.txt" ]; then
        echo "### Approach A — Distributed Cluster" >> "$outfile"
        echo '```' >> "$outfile"
        grep -A 5 "Summary:" "$RESULTS_DIR/approach-A-distributed-results.txt" >> "$outfile" 2>/dev/null || true
        echo '```' >> "$outfile"
        echo "" >> "$outfile"

        echo "### Approach A — Resources" >> "$outfile"
        echo '```' >> "$outfile"
        cat "$RESULTS_DIR/approach-A-resources.txt" >> "$outfile" 2>/dev/null || true
        echo '```' >> "$outfile"
        echo "" >> "$outfile"
    fi

    if [ -f "$RESULTS_DIR/approach-B-readonly-results.txt" ]; then
        echo "### Approach B — Read-Only Replicas" >> "$outfile"
        echo '```' >> "$outfile"
        grep -A 5 "Summary:" "$RESULTS_DIR/approach-B-readonly-results.txt" >> "$outfile" 2>/dev/null || true
        echo '```' >> "$outfile"
        echo "" >> "$outfile"

        echo "### Approach B — Resources" >> "$outfile"
        echo '```' >> "$outfile"
        cat "$RESULTS_DIR/approach-B-resources.txt" >> "$outfile" 2>/dev/null || true
        echo '```' >> "$outfile"
    fi

    log "Comparison report: $outfile"
}

# Main
MODE="${1:-both}"

case "$MODE" in
    distributed|a|A)
        test_distributed
        ;;
    readonly|b|B)
        test_readonly
        ;;
    both|all)
        test_distributed
        echo ""
        echo ""
        test_readonly
        generate_comparison
        ;;
    *)
        echo "Usage: $0 [distributed|readonly|both]"
        exit 1
        ;;
esac

log "All benchmarks complete! Results in: $RESULTS_DIR/"
