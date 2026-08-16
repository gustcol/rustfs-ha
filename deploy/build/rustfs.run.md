# RustFS Service Installation Guide

## 1. Prerequisites

### 1.1 Create System User

```bash
# Create rustfs system user and group without login shell
sudo useradd -r -s /sbin/nologin rustfs
```

### 1.2 Create Required Directories

Replace `/srv/rustfs` below with the actual mount point of the storage backing
your volumes (a ZFS dataset, an LVM volume, etc.). If the data path lives on a
separate filesystem, make sure it is mounted (and listed in `/etc/fstab` or
managed by a `.mount` unit) **before** starting the service — see the
`RequiresMountsFor=` note in step 3.

```bash
# Create program directory
sudo mkdir -p /opt/rustfs

# Create data directories (one per volume)
sudo mkdir -p /srv/rustfs/{vol1,vol2}

# Create configuration directory
sudo mkdir -p /etc/rustfs

# Set directory permissions
sudo chown -R rustfs:rustfs /opt/rustfs /srv/rustfs
sudo chmod 755 /opt/rustfs /srv/rustfs
```

> **ZFS/LVM caution:** if the dataset or logical volume that provides
> `/srv/rustfs` is not yet mounted when you run `mkdir -p`, you will create an
> empty directory on the *root* filesystem instead. When the real dataset
> mounts later, RustFS will keep writing into (or fail to find data in) the
> wrong, empty mountpoint. Confirm the mount is active first (`mount | grep
> rustfs` or `zfs list`), then create the subdirectories.

## 2. Install RustFS

```bash
# Copy RustFS binary
sudo cp rustfs /usr/local/bin/
sudo chmod +x /usr/local/bin/rustfs

# Copy configuration file
sudo cp obs.yaml /etc/rustfs/
sudo chown -R rustfs:rustfs /etc/rustfs
```

## 3. Configure Systemd Service

```bash
# Copy service unit file
sudo cp rustfs.service /etc/systemd/system/

# Copy and edit the environment file (sets RUSTFS_VOLUMES, RUSTFS_OPTS, credentials, etc.)
sudo cp ../config/rustfs.env /etc/default/rustfs
sudo $EDITOR /etc/default/rustfs

# Reload systemd configuration
sudo systemctl daemon-reload
```

`rustfs.service` uses `EnvironmentFile=/etc/default/rustfs` and expects
**exactly one** `ExecStart` line:

```
ExecStart=/usr/local/bin/rustfs $RUSTFS_VOLUMES $RUSTFS_OPTS
```

A few things about this line that are easy to get wrong:

- **Volumes are positional arguments**, not a `--volumes` flag. The `rustfs`
  binary is invoked as `rustfs [FLAGS] <VOL1> <VOL2> ...`. Set
  `RUSTFS_VOLUMES="/srv/rustfs/vol1 /srv/rustfs/vol2"` (space-separated) in
  `/etc/default/rustfs`.
- The `$RUSTFS_VOLUMES` reference in `ExecStart` must stay **unbraced**
  (`$RUSTFS_VOLUMES`, not `${RUSTFS_VOLUMES}`). Systemd only splits an
  environment variable into multiple arguments on whitespace when it is
  referenced unbraced; the braced form is passed through as a single
  argument and `rustfs` will fail to parse it as separate volumes.
- `RUSTFS_OPTS` carries the remaining flags, e.g.
  `RUSTFS_OPTS="--address 0.0.0.0:9000 --console-enable"`.
- Don't define two `ExecStart=` lines. `rustfs` runs as `Type=notify`, and
  for `Type=notify` services a second `ExecStart=` is invalid config (not
  just redundant) — systemd only permits multiple `ExecStart=` for oneshot
  services, and the notify readiness protocol won't work reliably if it
  fires for the wrong invocation. Keep exactly one line, driven entirely by
  the environment file.
- `RequiresMountsFor=/srv/rustfs` in the `[Unit]` section makes systemd order
  the service to start *after* that path is mounted. This matters
  specifically on ZFS/LVM hosts: without it, a boot-time race can start
  `rustfs` before the dataset mounts, so it writes its erasure-coded volumes
  into the empty directory created by `mkdir -p` instead of the real
  storage. Update this path to match your actual data mount.
- `ReadWritePaths=` in the `[Service]` section must match the actual volumes
  path (`/srv/rustfs` by default in the shipped unit), or `ProtectSystem=full`
  will block writes to it.

## 4. TLS

RustFS enables TLS when a certificate directory is provided via `--tls-path
<DIR>` (or the `RUSTFS_TLS_PATH` environment variable — already set in the
shipped `rustfs.env` example). RustFS looks for exactly these two files in
that directory:

- `rustfs_cert.pem`
- `rustfs_key.pem`

(see `rustfs/src/server/cert.rs` and `rustfs/src/server/http.rs` for the
loading logic.) Optional additional files in the same directory:

- `ca.crt` / `public.crt` — extra root CA certificates trusted for inter-node
  and outbound connections.
- `client_cert.pem` / `client_key.pem` — optional mTLS client identity used
  for outbound/inter-node calls.

```bash
sudo mkdir -p /etc/rustfs/tls
sudo cp rustfs_cert.pem rustfs_key.pem /etc/rustfs/tls/
sudo chown -R rustfs:rustfs /etc/rustfs/tls
sudo chmod 700 /etc/rustfs/tls
```

Then set in `/etc/default/rustfs`:

```
RUSTFS_TLS_PATH=/etc/rustfs/tls
```

No other flag is required — RustFS picks up `RUSTFS_TLS_PATH` from the
environment automatically. Restart the service after changing certificates.

## 5. Service Management

### 5.1 Start Service

```bash
sudo systemctl start rustfs
```

### 5.2 Check Service Status

```bash
sudo systemctl status rustfs
```

### 5.3 Enable Auto-start

```bash
sudo systemctl enable rustfs
```

### 5.4 View Service Logs

Logs go to the systemd journal — there is no separate log file to manage or
rotate.

```bash
# View real-time logs
sudo journalctl -u rustfs -f

# View today's logs
sudo journalctl -u rustfs --since today
```

## 6. Verify Installation

```bash
# Check service ports
ss -tunlp | grep 9000

# Test service availability (add -k or use https:// if TLS is enabled)
curl -I http://localhost:9000
```
