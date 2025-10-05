# oci-secretsync

> **Zero-drama secrets for containers on OCI.**
> Fetch from **OCI Vault**, write to **tmpfs**, **signal** containers that can hot-reload. No env-vars in git. No weekly mass restarts. No tears.

[![Status](https://img.shields.io/badge/status-stable-brightgreen)](#) [![OCI](https://img.shields.io/badge/cloud-Oracle_Cloud-red)](#) [![Secrets](https://img.shields.io/badge/secrets-OCI_Vault-blue)](#)

---

## Why this exists

* You want **OCI Vault** as the source of truth for secrets.
* Your services run in **Docker/Podman** on OCI (or anywhere with OCI instance principals).
* Some containers can **hot-reload** creds with a signal; others can’t. You need one pattern that handles both—without sprinkling plain-text env files everywhere.

---

## What it does (in one breath)

1. Reads a tiny **map file** (`/etc/oci-secretsync/map.csv`) telling it *which secret OCID → which file path*, and optionally *which container to signal* when the value changes.
2. Pulls the **CURRENT** version from **OCI Vault** using **instance principals** (no API keys on disk).
3. Writes the secret **atomically** into **`/run/secrets` (tmpfs)** with your chosen mode (e.g., `0600`).
4. If content changed, sends a **signal** (e.g., `HUP`, `USR1`) to the named container.
5. Rinse and repeat on a **systemd timer** (default: every 6h).

---

## Quick start

> TL;DR to get from zero → working in ~5 minutes.

### 1) Create the tmpfs and mapping file

```bash
sudo install -d -m 0700 /run/secrets
sudo mkdir -p /etc/oci-secretsync
sudo tee /etc/oci-secretsync/map.csv >/dev/null <<'CSV'
# ocid,path,mode,container,signal
ocid1.vaultsecret.oc1..aaaa...dbpass,/run/secrets/db_password,0600,myapp,HUP
ocid1.vaultsecret.oc1..bbbb...smtpcred,/run/secrets/smtp_password,0600,mailrelay,USR1
ocid1.vaultsecret.oc1..cccc...apikey,/run/secrets/my_api_key,0400,,
CSV
```

### 2) Install the sync script

Save as `/usr/local/bin/oci-secretsync` and `chmod 0755`:

```bash
#!/usr/bin/env bash
set -euo pipefail

MAP_FILE="${1:-/etc/oci-secretsync/map.csv}"
OCI="${OCI_CLI_BIN:-oci}"
TMPDIR="/run/secrets/.tmp"
mkdir -p "$TMPDIR"; chmod 0700 "$TMPDIR"

export OCI_CLI_AUTH=instance_principal

read_csv()  { grep -vE '^\s*$|^\s*#' "$1"; }
fetch_secret() {
  $OCI secrets secret-bundle get --secret-id "$1" --stage CURRENT \
    --query 'data."secret-bundle-content".content' --raw-output | base64 -d
}
atomic_write_if_changed() {
  local content="$1" path="$2" mode="$3" tmp="$TMPDIR/.$(basename "$2").$$"
  umask 077; printf '%s' "$content" > "$tmp"; chmod "$mode" "$tmp"
  if [ ! -f "$path" ] || ! cmp -s "$tmp" "$path"; then mv -f "$tmp" "$path"; return 0; fi
  rm -f "$tmp"; return 1
}
signal_container() {
  local name="$1" sig="$2"; [ -z "$name" -o -z "$sig" ] && return 0
  if command -v docker >/dev/null; then docker kill --signal "$sig" "$name" >/dev/null 2>&1 || true
  elif command -v podman >/dev/null; then podman kill --signal "$sig" "$name" >/dev/null 2>&1 || true
  fi
}

changed_any=0
while IFS=, read -r ocid path mode container signal; do
  val="$(fetch_secret "$ocid")" || { echo "ERR: fetch $ocid failed"; continue; }
  if atomic_write_if_changed "$val" "$path" "$mode"; then
    echo "Updated $path from $ocid"
    changed_any=1
    signal_container "$container" "$signal"
  fi
done < <(read_csv "$MAP_FILE")

[ "$changed_any" -eq 1 ] && exit 3 || exit 0
```

### 3) Systemd units (timer + mount)

`/etc/systemd/system/run-secrets.mount`

```ini
[Unit]
Description=tmpfs for container secrets
After=network.target

[Mount]
What=tmpfs
Where=/run/secrets
Type=tmpfs
Options=mode=0700,noexec,nosuid,nodev,size=8M

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/oci-secretsync.service`

```ini
[Unit]
Description=Sync secrets from OCI Vault to /run/secrets
Wants=network-online.target
After=network-online.target run-secrets.mount

[Service]
Type=oneshot
ExecStart=/usr/local/bin/oci-secretsync /etc/oci-secretsync/map.csv
User=root
Group=root
SuccessExitStatus=0 3
```

`/etc/systemd/system/oci-secretsync.timer`

```ini
[Unit]
Description=Run oci-secretsync periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
```

Enable everything:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now run-secrets.mount oci-secretsync.timer
sudo systemctl start oci-secretsync.service   # test a run now
journalctl -u oci-secretsync.service -n 100 -f
```

---

## OCI prerequisites

* **OCI CLI** installed on the host.
* The host is in a **Dynamic Group** (instance principals enabled).
* Compartment **Policy** (minimum):

  ```
  Allow dynamic-group <your-dg> to read secret-bundles in compartment <your-compartment>
  ```
* You’ve created **Secrets** in **OCI Vault** and have their **OCIDs**.

---

## Using in Docker/Podman (compose pattern)

```yaml
services:
  myapp:
    image: ghcr.io/example/myapp:latest
    environment:
      # app reads secret from a file (safer than env value)
      DB_PASSWORD_FILE: /run/secrets/db_password
    volumes:
      - /run/secrets:/run/secrets:ro
    restart: unless-stopped
```

> If your app insists on env vars, add a tiny wrapper entrypoint inside the image that reads file → exports env → execs the real binary. You still get seamless file updates later.

---

## Map file format

`/etc/oci-secretsync/map.csv`

```
ocid,path,mode,container,signal
```

* **`ocid`**: Secret OCID in OCI Vault
* **`path`**: Where to write it (usually under `/run/secrets/...`)
* **`mode`**: File mode (e.g., `0600`, `0400`)
* **`container`** *(optional)*: Container name to signal
* **`signal`** *(optional)*: Signal to send (e.g., `HUP`, `USR1`)

Lines starting with `#` are ignored.

---

## Common containers & signals (cheat sheet)

| Component           | Reload secret without restart? | Typical signal                       |
| ------------------- | ------------------------------ | ------------------------------------ |
| nginx               | Yes (config/keys)              | `HUP` or `USR1`                      |
| HAProxy             | Yes (graceful)                 | `USR2` (or runtime API)              |
| Traefik             | Generally dynamic              | often none needed                    |
| Postfix             | Partially                      | `HUP`                                |
| Dovecot             | Yes                            | `HUP`                                |
| OpenLDAP            | Yes                            | `HUP`                                |
| Node/Go custom apps | Add handler                    | usually `HUP`                        |
| Many vendor images  | No                             | leave blank → pick up on next deploy |

> If in doubt: leave `container,signal` empty. You’ll get updated files now; the app adopts them on its next planned restart.

---

## Security notes (worth actually reading)

* **No secrets in git**: nothing here requires committing creds.
* **tmpfs only**: `/run/secrets` is memory-backed; secrets disappear on reboot.
* **Least privilege**: dynamic group limited to **read secret-bundles**.
* **Audit trail**: every Vault read is logged in OCI—useful when things go bang.
* **Don’t spam Vault**: the timer fetches every few hours, not every request.

---

## Testing rotation safely

1. **Rotate** the secret in OCI Vault (create new version, mark **CURRENT**).
2. `sudo systemctl start oci-secretsync.service` (or wait for timer).
3. Check logs → “Updated … from …”.
4. If you set a signal, confirm the process reloaded (e.g., `docker logs` or app health).
5. If the app cannot hot-reload, plan a **graceful rolling restart** at your convenience. No fire drills.

---

## Troubleshooting

* **`ERR: fetch ... failed`**
  Check IAM: dynamic group & policy are correct; the instance is actually in that group.
* **“No such container” on signal**
  The name in `map.csv` must match `docker ps --format '{{.Names}}'`.
* **File exists but app won’t see new value**
  App doesn’t reload; leave the signal blank and restart it on your schedule.
* **Secrets missing after reboot**
  Ensure `run-secrets.mount` is enabled and `oci-secretsync.timer` is active.

---

## Architecture (ASCII edition)

```
+--------------------+            +--------------------+
|   OCI Vault        |            |   OCI IAM          |
|  (Secrets, KMS)    |            | (Dynamic Group)    |
+---------+----------+            +---------+----------+
          |                                 |
          | read secret-bundle (CURRENT)    | auth: instance principal
          v                                 v
+---------+---------------------------------+---------+
|                Host (VM/Bare metal)                 |
|  /run/secrets (tmpfs)   oci-secretsync (systemd)    |
|      ^                         |                    |
|      | atomic write            | signal (opt.)      |
+------+-------------------------+--------------------+
       |                         |
       v                         v
  Containers read         Containers hot-reload
  files on start          on HUP/USR1/... (if supported)
```

---

## FAQ

**Why not Docker/Swarm/Podman “native secrets”?**
Those stores don’t natively source from **OCI Vault**. Here, Vault remains the source of truth and the host syncs it—to any runtime.

**Can I run this outside OCI?**
Yes, as long as the machine can authenticate to OCI (instance principals or a short-lived token). Instance principals are cleaner.

**How often should I sync?**
Every few hours is sane. Rotations aren’t per-minute events, and Vault isn’t your hot path.

---

## License

Choose your poison (MIT/Apache-2.0). Fill this in if you care about lawyers.

---

## Contributing

Open a PR with:

* new signal recipes for popular images,
* guardrails you’ve added (e.g., NSG requirements, proxy patterns),
* or a wrapper entrypoint that upgrades env-only images to file-based secrets.

---

**That’s it.** Point your containers at `/run/secrets/*`, add their OCIDs to `map.csv`, and let the timer get on with it. If a service can’t hot-reload, don’t over-engineer—just leave it be and it’ll pick up the new secret next time you redeploy.
