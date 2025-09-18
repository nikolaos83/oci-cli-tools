#!/usr/bin/env bash
# oci_sync-ips-to-host.sh
# Fetches secondary IPs for a VNIC and generates a Netplan configuration
# on the corresponding host to apply them.

set -euo pipefail

# --- functions ---

usage() {
    echo "Usage: $0 <VNIC_ID>"
    echo "  Syncs all secondary IPs from a VNIC to the host's Netplan configuration."
    echo
    echo "  <VNIC_ID>: The OCID of the VNIC to sync."
    echo
    echo "Prerequisites:"
    echo "  - OCI CLI is configured."
    echo "  - SSH key-based authentication is set up from this machine to the target host."
    echo "  - The remote user has passwordless sudo privileges for the 'tee' command."
    exit 1
}

# --- main ---

if [ "$#" -ne 1 ]; then
    usage
fi

VNIC_ID=$1
DB_DIR="/home/scripts/DB"

# 1. Data Gathering
echo "[*] Fetching all private IPs for VNIC: $VNIC_ID"
PRIVATE_IPS_JSON=$(oci network private-ip list --vnic-id "$VNIC_ID" --all)
IPV6S_JSON=$(oci network ipv6 list --vnic-id "$VNIC_ID" --all)

PRIMARY_IP_JSON=$(echo "$PRIVATE_IPS_JSON" | jq '.data[] | select(."is-primary" == true)')
PRIMARY_IP=$(echo "$PRIMARY_IP_JSON" | jq -r '."ip-address"')
PRIMARY_HOSTNAME=$(echo "$PRIMARY_IP_JSON" | jq -r '."hostname-label"')

# Collect IPv4s
SECONDARY_IPV4S=$(echo "$PRIVATE_IPS_JSON" | jq -r '.data[] | select(."is-primary" == false and ."ip-address" != null) | ."ip-address"' | sort -V)

# Collect IPv6s
SECONDARY_IPV6S=$(echo "$IPV6S_JSON" | jq -r '.data[] | select(."ip-address" != null) | ."ip-address"' | sort -V)

# Combine
ALL_SECONDARY_IPS=$(echo -e "$SECONDARY_IPV4S\n$SECONDARY_IPV6S" | sed '/^$/d')

if [[ -z "$PRIMARY_IP" || -z "$PRIMARY_HOSTNAME" ]]; then
    echo "[!] Failed to retrieve primary IP or hostname for VNIC $VNIC_ID. Aborting." >&2
    exit 1
fi

echo "[✓] Found Primary IP: $PRIMARY_IP"
echo "[✓] Found Primary Hostname: $PRIMARY_HOSTNAME"

# 2. Local Database File
mkdir -p "$DB_DIR"
DB_FILE="$DB_DIR/$PRIMARY_HOSTNAME-IP-list.db"

echo "[*] Writing IP information to local database: $DB_FILE"
{
    echo "# Host: $PRIMARY_HOSTNAME"
    echo "# VNIC: $VNIC_ID"
    echo "# Primary IP: $PRIMARY_IP"
    echo "# Generated on: $(date)"
    echo ""
    echo "# [IPv4 Secondary IPs]"
    if [[ -n "$SECONDARY_IPV4S" ]]; then
        echo "$SECONDARY_IPV4S"
    else
        echo "# (None)"
    fi
    echo ""
    echo "# [IPv6 Secondary IPs]"
    if [[ -n "$SECONDARY_IPV6S" ]]; then
        echo "$SECONDARY_IPV6S"
    else
        echo "# (None)"
    fi
} > "$DB_FILE"
echo "[✓] Database file written."

# 3. Sanity Check for IPs
if [[ -z "$ALL_SECONDARY_IPS" ]]; then
    echo "[i] No secondary IPs found for this VNIC. Nothing to sync."
    echo "[✔] Sync process complete."
    exit 0
fi

# Step A: Discover the primary network interface name
echo "[*] Discovering primary network interface on remote host..."
REMOTE_INTERFACE=$(ssh -qT \
  -o "StrictHostKeyChecking=no" \
  -o "UserKnownHostsFile=/dev/null" \
  "$PRIMARY_IP" \
  "ip route get 8.8.8.8 | awk '{print \$5; exit}'")

# Step B: Sanity check
if [[ -z "$REMOTE_INTERFACE" ]] || ! [[ "$REMOTE_INTERFACE" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "[!] Could not determine a valid remote network interface. Discovered: '$REMOTE_INTERFACE'. Aborting." >&2
    exit 1
fi
echo "[✓] Discovered remote interface: $REMOTE_INTERFACE"

# Step C: Discover the gateway

# Step C: Discover the gateway
echo "[*] Discovering gateway on remote host..."
GATEWAY=$(ssh -qT \
  -o "StrictHostKeyChecking=no" \
  -o "UserKnownHostsFile=/dev/null" \
  "$PRIMARY_IP" \
  "ip route show default | head -n 1 | awk '{print \$3}'")

if [[ -z "$GATEWAY" ]]; then
    echo "[!] Could not determine the gateway on the remote host. Aborting." >&2
    exit 1
fi
echo "[✓] Discovered gateway: $GATEWAY"

# Step D+E: Generate and send the new Netplan YAML content directly
echo "[*] Generating and writing Netplan configuration for secondary IPs..."

REMOTE_NETPLAN_FILE="/etc/netplan/90-script-addons.yaml"

ssh -T -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" "$PRIMARY_IP" "sudo tee $REMOTE_NETPLAN_FILE > /dev/null" <<EOF
network:
  version: 2
  ethernets:
    $REMOTE_INTERFACE:
      addresses:
$(for ip in $ALL_SECONDARY_IPS; do
    if [[ "$ip" == *":"* ]]; then
        echo "        - $ip/128"
    else
        echo "        - $ip/32"
    fi
done)
      routes:
$( 
    table_num=100
    for ip in $SECONDARY_IPV4S; do
        echo "        - to: default"
        echo "          via: $GATEWAY"
        echo "          table: $table_num"
        echo "          on-link: true"
        table_num=$((table_num + 1))
    done
)
      routing-policy:
$( 
    table_num=100
    for ip in $SECONDARY_IPV4S;
 do
        echo "        - from: $ip"
        echo "          table: $table_num"
        table_num=$((table_num + 1))
    done
)
EOF



echo "[✓] Successfully wrote Netplan config to $REMOTE_NETPLAN_FILE on host $PRIMARY_HOSTNAME."
echo


# 5. User Notification
echo "--- ACTION REQUIRED ---"
echo "To apply the new network configuration, SSH into the host ($PRIMARY_IP) and run the following command:"
echo


echo "  sudo netplan apply"
echo "-----------------------"
echo

echo "[✔] Sync process complete."
