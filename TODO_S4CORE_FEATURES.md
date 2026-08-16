# Features a portar do S4Core para RustFS-HA

> Criado: 2026-04-07 | Status: Pendente implementacao

## 1. Content Deduplication (Alta prioridade)

### O que existe hoje
- `crates/rio/src/hash_reader.rs` — ja calcula blake3 hash durante reads
- `crates/ecstore/src/erasure_coding/` — erasure encode/decode
- `crates/filemeta/src/filemeta/version.rs` — metadata de versao com hashes

### O que implementar

Criar `crates/dedup/` com a seguinte estrutura:

```
crates/dedup/
  Cargo.toml
  src/
    lib.rs              -- pub trait DeduplicationEngine
    refcount_store.rs   -- Store: content_hash -> (refcount, shard_locations[])
    dedup_writer.rs     -- Intercepta PutObject pre-erasure encoding
    dedup_gc.rs         -- Background worker: refcount=0 -> cleanup
    config.rs           -- DeduplicationConfig (enable/disable, min_size threshold)
```

### Cargo.toml

```toml
[package]
name = "rustfs-dedup"
version = "0.0.5"
edition.workspace = true
license.workspace = true

[dependencies]
rustfs-common = { workspace = true }
rustfs-rio = { workspace = true }
blake3 = { workspace = true }
serde = { workspace = true }
serde_json = { workspace = true }
tokio = { workspace = true }
tracing = { workspace = true }
anyhow = { workspace = true }
parking_lot = { workspace = true }
```

### Fluxo de deduplication

```
PutObject request
    |
    v
HashReader calcula blake3 do objeto inteiro (ja existe)
    |
    v
DeduplicationEngine::lookup(hash)
    |
    +-- HIT: refcount++ no store, criar metadata pointer, SKIP erasure write
    |       Retorna sucesso com ETag do objeto existente
    |
    +-- MISS: erasure encode normal, salvar hash -> locations no refcount store
             refcount = 1
```

### refcount_store.rs — Schema

```rust
use std::collections::HashMap;
use std::path::PathBuf;

/// Chave: blake3 hash (32 bytes hex = 64 chars)
/// Valor: metadata de dedup
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DedupEntry {
    /// Quantos objects apontam para estes dados
    pub refcount: u64,
    /// Tamanho original do objeto
    pub size: u64,
    /// Locations dos erasure shards no disco
    pub shard_locations: Vec<PathBuf>,
    /// Timestamp da primeira escrita
    pub created_at: chrono::DateTime<chrono::Utc>,
    /// Timestamp do ultimo refcount update
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

/// Store persistido em disco (usar fjall ou sled)
pub struct RefcountStore {
    /// Path: {data_dir}/.rustfs/dedup/refcount.db
    db_path: PathBuf,
    /// In-memory index (loaded on startup)
    entries: parking_lot::RwLock<HashMap<String, DedupEntry>>,
}

impl RefcountStore {
    pub fn new(data_dir: &std::path::Path) -> anyhow::Result<Self> { todo!() }
    pub fn lookup(&self, hash: &str) -> Option<DedupEntry> { todo!() }
    pub fn insert(&self, hash: String, entry: DedupEntry) -> anyhow::Result<()> { todo!() }
    pub fn increment(&self, hash: &str) -> anyhow::Result<()> { todo!() }
    pub fn decrement(&self, hash: &str) -> anyhow::Result<u64> { todo!() }
    pub fn gc_candidates(&self) -> Vec<String> { todo!() }
}
```

### dedup_writer.rs — Integracao com ecstore

Ponto de integracao: `crates/ecstore/src/store.rs`
No metodo put_object(), ANTES de chamar erasure encode:

1. `let hash = hash_reader.finalize_blake3();`
2. Lookup no dedup_store
3. Se HIT: increment refcount, criar metadata pointer, retornar
4. Se MISS: erasure encode normal, inserir no dedup_store

### dedup_gc.rs — Garbage Collector

Background worker que roda periodicamente (ex: 6h):
1. Scan refcount store por entries com refcount == 0
2. Verificar que nenhum metadata aponta para os shards (double-check)
3. Deletar shards do disco
4. Remover entry do refcount store

Config via env vars:
- RUSTFS_DEDUP_ENABLED=true
- RUSTFS_DEDUP_MIN_SIZE=1048576  (1MB -- skip dedup para files pequenos)
- RUSTFS_DEDUP_GC_INTERVAL_HOURS=6

### Onde modificar codigo existente
1. `Cargo.toml` (workspace) — adicionar `"crates/dedup"` em members
2. `crates/ecstore/src/store.rs` — hook no put_object antes do erasure encode
3. `crates/ecstore/src/store.rs` — hook no delete_object para decrement refcount
4. `rustfs/src/app/object_usecase.rs` — passar dedup config ao ecstore
5. `crates/config/` — adicionar DeduplicationConfig

---

## 2. Multi-Object SQL Query (Media prioridade)

### O que existe hoje
- `crates/s3select-api/` — S3 Select single-object (DataFusion-based)
- `crates/s3select-query/` — Query engine com CSV/JSON/Parquet support
- `datafusion = "52.1.0"` ja no workspace

### Novo endpoint

```
POST /{bucket}?sql
Content-Type: application/json

{
    "sql": "SELECT * FROM 'logs/*.csv' WHERE status = 'ERROR'",
    "format": "csv",
    "output": "json"
}
```

### Arquivos a criar/modificar

**Novo: `crates/s3select-api/src/server/multi_object.rs`**

```rust
/// Handler para POST /{bucket}?sql
///
/// Fluxo:
/// 1. Parse request body -> MultiObjectQuery { sql, format, output }
/// 2. Extrair glob pattern do FROM clause (ex: 'logs/*.csv')
/// 3. ListObjects no bucket com prefix extraido do glob
/// 4. Filtrar objects que matcham o glob pattern
/// 5. Para cada object, criar DataFusion TableProvider
/// 6. UNION ALL dos providers
/// 7. Executar SQL query
/// 8. Stream resultado no formato solicitado

use datafusion::prelude::*;
use glob::Pattern;

pub struct MultiObjectQuery {
    pub sql: String,
    pub format: String,
    pub output: String,
}

/// Extrair glob do FROM clause
/// "SELECT * FROM 'logs/*.csv' WHERE x > 1"
/// -> glob_pattern = "logs/*.csv"
/// -> rewritten_sql = "SELECT * FROM unified_table WHERE x > 1"
fn extract_glob_from_sql(sql: &str) -> anyhow::Result<(String, String)> {
    // Regex: FROM\s+'([^']+)'
    // Substituir por FROM unified_table
    todo!()
}

/// Resolver glob contra ListObjects
async fn resolve_glob_to_keys(
    storage: &dyn StorageAPI,
    bucket: &str,
    glob_pattern: &str,
) -> anyhow::Result<Vec<String>> {
    let pattern = Pattern::new(glob_pattern)?;
    // ListObjects com prefix otimizado
    // Filtrar com glob::Pattern::matches
    todo!()
}
```

**Modificar: `crates/s3select-api/src/server/mod.rs`**
- Adicionar rota `POST /{bucket}?sql` -> `multi_object::handle_multi_sql`

**Modificar: `rustfs/src/server/http.rs`**
- Registrar nova rota no router

### Dependencias extras
```toml
# Em crates/s3select-api/Cargo.toml, adicionar:
glob = { workspace = true }
```

---

## Prioridade de execucao

1. **Multi-Object SQL** — menos invasivo, reusa 90% do codigo existente (~500-800 linhas)
2. **Content Deduplication** — mais impactante mas toca no core do storage engine

## Comandos para comecar

```bash
cd rustfs-ha

# 1. Criar branch
git checkout -b feature/s4core-ports

# 2. Criar crate de dedup
mkdir -p crates/dedup/src

# 3. Adicionar ao workspace
# Editar Cargo.toml, adicionar "crates/dedup" em [workspace.members]

# 4. Build incremental
cargo check -p rustfs-dedup

# 5. Para multi-object SQL
# Editar crates/s3select-api/src/server/
# cargo check -p rustfs-s3select-api
```

## Benchmark S4Core vs MinIO (referencia de 2026-04-07)

| Metrica     | S4Core    | MinIO     |
|-------------|-----------|-----------|
| 100 PUTs    | 1m32s     | 1m34s     |
| RAM         | 16 MiB    | 382 MiB   |
| CPU (idle)  | 0.00%     | 7.28%     |
| Block I/O   | 64 MB     | 1.95 GB   |

## Referencias
- S4Core source: https://github.com/s4core/s4core
- S4Core Multi-Object SQL: POST /{bucket}?sql endpoint
- S4Core Dedup: Bitcask append-only + content-addressable store
- DataFusion docs: https://datafusion.apache.org/
