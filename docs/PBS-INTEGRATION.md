# Using RustFS as an S3 Backend for Proxmox Backup Server

This guide covers configuring [Proxmox Backup Server](https://www.proxmox.com/en/proxmox-backup-server) (PBS)
4.x to use a RustFS bucket as the object storage backend for a datastore, via PBS's native S3 datastore
support. The steps below were verified end-to-end on a real deployment (endpoint creation, bucket creation,
datastore creation, a live backup, and a `verify` run).

## 1. RustFS must serve TLS

PBS's S3 client is **HTTPS-only** — it will not talk to a plaintext S3 endpoint. RustFS must be running with
TLS enabled (see the TLS section in [`deploy/build/rustfs.run.md`](../deploy/build/rustfs.run.md)) before you
create the PBS endpoint.

- **Publicly-trusted certificates** (e.g. Let's Encrypt) work out of the box — no extra PBS configuration
  needed.
- **Self-signed certificates** require the `--fingerprint` option when creating the PBS S3 endpoint (below),
  so PBS can pin and trust that specific certificate instead of validating against a CA chain.

## 2. Create the S3 endpoint in PBS

```bash
proxmox-backup-manager s3 endpoint create <id> \
  --endpoint <fqdn> \
  --port 9000 \
  --access-key <access-key> \
  --secret-key <secret-key> \
  --path-style true \
  --region us-east-1
```

`--path-style true` is **required**. RustFS does not do wildcard vhost-style DNS
(`<bucket>.<fqdn>`) by default, so PBS must address buckets as
`https://<fqdn>:9000/<bucket>/...` rather than
`https://<bucket>.<fqdn>:9000/...`. Without `--path-style true`, requests will fail to resolve.

`--region` is required by the PBS CLI/S3 client even though RustFS does not enforce AWS-style regions; any
value RustFS accepts (e.g. `us-east-1`) is fine.

If you're using a self-signed certificate, add `--fingerprint <sha256-fingerprint>` (obtain it with
`openssl x509 -in rustfs_cert.pem -noout -fingerprint -sha256`).

## 3. Create a bucket in RustFS

Create the destination bucket in RustFS through the console, `mc`, or any S3-compatible client before
creating the PBS datastore — PBS does not create the bucket for you.

## 4. Create the PBS datastore

```bash
proxmox-backup-manager datastore create <name> <local-cache-path> \
  --backend type=s3,client=<id>,bucket=<bucket>
```

`<local-cache-path>` is a local directory PBS uses for chunk caching and metadata; the actual chunk data
lives in the RustFS bucket. `<id>` is the endpoint id created in step 2.

## 5. Validate

Run a real backup against the datastore, then verify it:

```bash
proxmox-backup-client backup <snapshot-name>.pxar:/path/to/backup --repository <user>@pbs!<token>@<pbs-host>:<name>
proxmox-backup-manager verify <name>
```

## Observed behavior

- PBS stores chunks under a `<datastore-name>/` prefix inside the bucket — one bucket can in principle host
  multiple datastores under separate prefixes, though it's simplest to keep one bucket per datastore.
- In testing, both the backup run and the subsequent `verify` completed with **zero errors**, confirming
  chunk upload, retrieval, and integrity checking all work correctly against a RustFS backend.

## Troubleshooting checklist

- **PBS reports it can't connect / TLS handshake failures:** confirm RustFS is actually serving TLS (not
  plaintext) on the configured port, and that the endpoint's certificate is either publicly trusted or the
  endpoint was created with the correct `--fingerprint`.
- **404 / routing errors on bucket access:** double check `--path-style true` was set on the endpoint; a
  missing or `false` value causes PBS to construct vhost-style URLs that RustFS won't resolve.
- **Datastore creation fails referencing the endpoint:** confirm the endpoint `<id>` from step 2 matches the
  `client=<id>` value passed to `--backend` in step 4 exactly.
