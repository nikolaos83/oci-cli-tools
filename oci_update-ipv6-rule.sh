#!/bin/bash

# --- Configuration ---
# The OCID of the Security List to update.
SEC_LIST_OCID="$Security_List"

# The description of the rule to update. This must be unique within the Security List.
RULE_DESCRIPTION="ALLOW_HOME_NETWORK@NET28"

# The username and hostname for the fallback SSH method.
SSH_USER_HOST="root@msm"

# Log file location
LOG_FILE="/var/log/oci_ipv6_update.log"
# --- End of Configuration ---

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

get_prefix_ssh() {
    log "Attempting to get IPv6 prefix via SSH from $SSH_USER_HOST..."
    CURRENT_PREFIX=$(ssh "$SSH_USER_HOST" "rdisc6 -1 wlan0" | awk '/Prefix/ {print $3; exit}')
}

# --- Main Script ---
log "--- Starting IPv6 update check ---"

# 1. Get the current IPv6 prefix
    get_prefix_ssh
    
if [ -z "$CURRENT_PREFIX" ]; then
    log "Error: Could not determine the current IPv6 prefix. Exiting."
    exit 1
fi

# Ensure we have a /64 prefix
if ! [[ "$CURRENT_PREFIX" == */64 ]]; then
    log "Error: The discovered address is not a /64 prefix: $CURRENT_PREFIX. Exiting."
    exit 1
fi

log "Successfully discovered current IPv6 prefix: $CURRENT_PREFIX"

# 2. Get the current Security List rules from OCI
log "Fetching current security list rules from OCI..."
RULES_JSON=$(oci network security-list get --security-list-id "$SEC_LIST_OCID" --query "data.\"ingress-security-rules\"" 2>&1)
if [ $? -ne 0 ]; then
    log "Error: Failed to fetch security list rules from OCI. Error: $RULES_JSON"
    exit 1
fi

# 3. Find the current prefix in the rule
log "Searching for rule with description: '$RULE_DESCRIPTION'"
EXISTING_PREFIX=$(echo "$RULES_JSON" | jq -r ".[] | select(.description==\"$RULE_DESCRIPTION\") | .source")

if [ -z "$EXISTING_PREFIX" ] || [ "$EXISTING_PREFIX" == "null" ]; then
    log "Error: Could not find a rule with the description '$RULE_DESCRIPTION'. Please create one in your OCI console. Exiting."
    exit 1
fi

log "Found existing prefix in OCI rule: $EXISTING_PREFIX"

# 4. Compare and update if necessary
if [ "$CURRENT_PREFIX" == "$EXISTING_PREFIX" ]; then
    log "Prefixes match. No update required. Exiting."
    exit 0
fi

log "Prefixes do not match. Updating OCI security rule..."

# 5. Construct the new ruleset
NEW_RULES_JSON=$(echo "$RULES_JSON" | jq "(.[] | select(.description==\"$RULE_DESCRIPTION\").source) |= \"$CURRENT_PREFIX\" ")

# 6. Update the Security List in OCI
log "Submitting update to OCI..."
UPDATE_RESULT=$(oci network security-list update --security-list-id "$SEC_LIST_OCID" --ingress-security-rules "$NEW_RULES_JSON" --force 2>&1)

if [ $? -eq 0 ]; then
    log "Successfully updated OCI security list. New prefix: $CURRENT_PREFIX"
else
    log "Error: Failed to update OCI security list. Error: $UPDATE_RESULT"
    exit 1
fi

log "--- IPv6 update check finished ---"
exit 0
