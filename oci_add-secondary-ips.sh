#!/usr/bin/env bash
# add-secondary-ips.sh
# Adds a range of secondary private IPs (v4 or v6) to a VNIC.

set -euo pipefail

# --- functions ---

usage() {
    echo "Usage: $0 <VNIC_ID> <START_IP> <COUNT>"
    echo "  Adds <COUNT> consecutive IP addresses to <VNIC_ID> starting from <START_IP>."
    echo
    echo "  <VNIC_ID>: The OCID of the VNIC."
    echo "  <START_IP>: The first IP address (IPv4 or IPv6) in the range."
    echo "  <COUNT>: The number of IPs to add."
    echo
    echo "Hostname/Display Name Logic:"
    echo "  - For IPv4, it creates a DNS hostname label in the format: <primary_hostname><last_two_octets>"
    echo "    (e.g., if primary is 'myhost' and IP is 10.0.64.10, label will be 'myhost6410')."
    echo "  - For IPv6, it sets a display name in the format: <primary_hostname><last_four_hex_chars>"
    echo "    (OCI does not support hostname labels for IPv6, so display name is used instead)."
    echo
    echo "Example (IPv4): $0 ocid1.vnic.oc1..example 10.0.64.10 5"
    echo "Example (IPv6): $0 ocid1.vnic.oc1..example 2001:db8:1:1::a 3"
    exit 1
}

# Fetches the hostname-label of the primary IPv4 on a VNIC
get_primary_hostname() {
    local vnic_id=$1
    echo "[*] Fetching primary hostname for VNIC $vnic_id..."
    local primary_hostname
    primary_hostname=$(oci network private-ip list --vnic-id "$vnic_id" --all | jq -r '.data[] | select(."is-primary" == true) | ."hostname-label"')
    
    if [[ -z "$primary_hostname" ]]; then
        echo "[!] Could not determine primary hostname-label for VNIC $vnic_id. Aborting." >&2
        exit 1
    fi
    echo "[✓] Found primary hostname: '$primary_hostname'"
    PRIMARY_HOSTNAME=$primary_hostname
}

# Adds a range of IPv4 addresses
add_ipv4() {
    local vnic_id=$1
    local start_ip=$2
    local count=$3

    get_primary_hostname "$vnic_id"

    IFS='.' read -r o1 o2 o3 o4 <<< "$start_ip"

    echo "[*] Starting to add $count IPv4 addresses to VNIC $vnic_id from $start_ip..."

    for i in $(seq 0 $((count - 1))); do
        current_o4=$((o4 + i))
        if [ $current_o4 -gt 255 ]; then
            echo "[!] IP address range exceeds 255 in the last octet. Aborting." >&2
            exit 1
        fi

        local current_ip="$o1.$o2.$o3.$current_o4"
        local hostname_label="${PRIMARY_HOSTNAME}${o3}${current_o4}"

        echo "[+] Adding IP: $current_ip with hostname-label: $hostname_label"
        oci network private-ip create \
            --vnic-id "$vnic_id" \
            --ip-address "$current_ip" \
            --hostname-label "$hostname_label" \
            
        
        if [ $? -ne 0 ]; then
            echo "[!] Failed to add IP $current_ip. Continuing..." >&2
        else
            echo "[✓] Successfully added $current_ip"
        fi
    done
}

# Adds a range of IPv6 addresses
add_ipv6() {
    local vnic_id=$1
    local start_ip=$2
    local count=$3

    get_primary_hostname "$vnic_id" # For display name prefix

    # Extract the prefix and the last segment of the IPv6 address
    local prefix="${start_ip%:*}:"
    local last_segment_hex
    last_segment_hex=$(echo "$start_ip" | awk -F: '{print $NF}')
    if [[ -z "$last_segment_hex" ]]; then
        last_segment_hex=0
    fi

    echo "[*] Starting to add $count IPv6 addresses to VNIC $vnic_id from $start_ip..."
    echo "[i] Note: OCI does not support DNS hostname labels for IPv6. Using display-name instead."

    for i in $(seq 0 $((count - 1))); do
        # Convert hex to decimal, increment, and convert back to hex
        local last_segment_dec=$((16#$last_segment_hex + i))
        local current_last_segment_hex
        current_last_segment_hex=$(printf "%x" $last_segment_dec)

        local current_ip="${prefix}${current_last_segment_hex}"
        local display_name="${PRIMARY_HOSTNAME}${current_last_segment_hex}"

        echo "[+] Adding IP: $current_ip with display-name: $display_name"
        oci network ipv6 create \
            --vnic-id "$vnic_id" \
            --ip-address "$current_ip" \
            --display-name "$display_name" \
            

        if [ $? -ne 0 ]; then
            echo "[!] Failed to add IP $current_ip. Continuing..." >&2
        else
            echo "[✓] Successfully added $current_ip"
        fi
    done
}

# --- main ---

if [ "$#" -ne 3 ]; then
    usage
fi

VNIC_ID=$1
START_IP=$2
COUNT=$3

if [[ $START_IP == *":"* ]]; then
    add_ipv6 "$VNIC_ID" "$START_IP" "$COUNT"
elif [[ $START_IP == *"."* ]]; then
    add_ipv4 "$VNIC_ID" "$START_IP" "$COUNT"
else
    echo "[!] Invalid IP address format: $START_IP" >&2
    usage
fi

echo "[✔] IP addition process complete."