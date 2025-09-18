#!/usr/bin/env bash
# oci_cleanup-secondary-ips.sh
# Usage: oci_cleanup-secondary-ips.sh [-4] [-6] <INSTANCE_OCID>

set -euo pipefail

# --- functions ---

usage() {
    echo "Usage: $0 [-4] [-6] <INSTANCE_OCID>"
    echo "  -4: Clean up only secondary IPv4 addresses."
    echo "  -6: Clean up ALL IPv6 addresses. WARNING: This will remove all IPv6 connectivity."
    echo "  If no flags are given, both IPv4 and IPv6 addresses are cleaned up."
    exit 1
}

cleanup_ipv4() {
    local VNIC_ID=$1
    echo "[*] Checking VNIC $VNIC_ID for secondary IPv4 IPs ..."
    local SECONDARIES=$(oci network private-ip list --vnic-id "$VNIC_ID" | jq -r '.data[] | select(."is-primary" == false) | .id')

    if [[ -n "$SECONDARIES" ]]; then
        for IP_ID in $SECONDARIES; do
            echo "[!] Deleting secondary IPv4 IP: $IP_ID"
            oci network private-ip delete --private-ip-id "$IP_ID" --force
        done
    else
        echo "[✓] No secondary IPv4 IPs found on $VNIC_ID"
    fi
}

cleanup_ipv6() {
    local VNIC_ID=$1
    echo "[*] Checking VNIC $VNIC_ID for IPv6 IPs ..."
    local IPV6_IDS=$(oci network ipv6 list --vnic-id "$VNIC_ID" | jq -r '.data[].id')

    if [[ -n "$IPV6_IDS" ]]; then
        for IPV6_ID in $IPV6_IDS; do
            echo "[!] Deleting IPv6 IP: $IPV6_ID"
            oci network ipv6 delete --ipv6-id "$IPV6_ID" --force
        done
    else
        echo "[✓] No IPv6 IPs found on $VNIC_ID"
    fi
}

# --- main ---

CLEANUP_IPV4=false
CLEANUP_IPV6=false

while getopts "46h" opt; do
    case ${opt} in
        4)
            CLEANUP_IPV4=true
            ;;
        6)
            CLEANUP_IPV6=true
            ;;
        h)
            usage
            ;;
        \?)
            usage
            ;;
    esac
done
shift $((OPTIND -1))

if [ "$#" -ne 1 ]; then
    usage
fi

INSTANCE_OCID="$1"

# If no flags are given, clean up both.
if [ "$CLEANUP_IPV4" = false ] && [ "$CLEANUP_IPV6" = false ]; then
    CLEANUP_IPV4=true
    CLEANUP_IPV6=true
fi

echo "[*] Fetching VNICs for instance $INSTANCE_OCID ..."
VNIC_IDS=$(oci compute instance list-vnics --instance-id "$INSTANCE_OCID" --query 'data[].id' | jq -r '.[]')

for VNIC_ID in $VNIC_IDS; do
    if [ "$CLEANUP_IPV4" = true ]; then
        cleanup_ipv4 "$VNIC_ID"
    fi
    if [ "$CLEANUP_IPV6" = true ]; then
        cleanup_ipv6 "$VNIC_ID"
    fi
done

echo "[✔] Cleanup complete."