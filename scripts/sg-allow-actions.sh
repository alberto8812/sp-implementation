#!/usr/bin/env bash
#
# sg-allow-actions.sh
#
# Operator-run script (NOT invoked by CI). Fetches GitHub Actions' published
# IPv4 ranges, loads them into an AWS managed prefix list, and adds one
# ingress rule on port 3306 to a target Security Group referencing that
# prefix list. Run this manually inside the demo window, right before the
# live push, and pair it with sg-revoke-actions.sh immediately after.
#
# Requirements: aws CLI (configured with credentials/region), curl, jq.
#
# Required environment variables:
#   SG_ID              Security Group ID to modify (e.g. sg-0123456789abcdef0)
#   PREFIX_LIST_NAME    Name for the managed prefix list (created if absent)
#
# Optional environment variables:
#   MAX_SG_RULE_ENTRIES  Safety threshold for entries added to the SG /
#                        prefix list in one run (default: 55, leaving margin
#                        under the AWS default 60-rule-per-SG quota).
#
# Exit codes: non-zero on any validation failure. The script aborts BEFORE
# applying anything to AWS if entries are malformed or would exceed quota —
# it never silently truncates the list.

set -euo pipefail

: "${SG_ID:?SG_ID environment variable is required (target Security Group ID)}"
: "${PREFIX_LIST_NAME:?PREFIX_LIST_NAME environment variable is required}"
MAX_SG_RULE_ENTRIES="${MAX_SG_RULE_ENTRIES:-55}"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found in PATH" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found in PATH" >&2; exit 1; }

# Strict IPv4 CIDR validation: dotted-quad octets 0-255, mask /0-/32.
CIDR_REGEX='^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])/([0-9]|[1-2][0-9]|3[0-2])$'

META_SOURCE="${GITHUB_META_SOURCE:-https://api.github.com/meta}"

echo "Fetching GitHub Actions published IP ranges from: ${META_SOURCE}"
meta_json="$(curl -sSL --fail "${META_SOURCE}")"

raw_entries=()
while IFS= read -r line; do
    [ -n "${line}" ] && raw_entries+=("${line}")
done < <(printf '%s' "${meta_json}" | jq -r '.actions[]')

if [ "${#raw_entries[@]}" -eq 0 ]; then
    echo "ERROR: no entries returned under .actions — aborting, nothing applied." >&2
    exit 1
fi

validated_entries=()
for entry in "${raw_entries[@]}"; do
    # IPv4 only — skip IPv6 (contains ':').
    case "${entry}" in
        *:*) continue ;;
    esac

    if [[ ! "${entry}" =~ ${CIDR_REGEX} ]]; then
        echo "ERROR: malformed/rejected CIDR entry encountered: '${entry}' — aborting, nothing applied." >&2
        exit 1
    fi

    validated_entries+=("${entry}")
done

entry_count="${#validated_entries[@]}"
echo "Validated IPv4 entry count: ${entry_count}"

if [ "${entry_count}" -eq 0 ]; then
    echo "ERROR: zero valid IPv4 entries after filtering — aborting, nothing applied." >&2
    exit 1
fi

if [ "${entry_count}" -gt "${MAX_SG_RULE_ENTRIES}" ]; then
    cat >&2 <<EOF
ERROR: entry count (${entry_count}) exceeds the safe threshold (${MAX_SG_RULE_ENTRIES}).

Applying this many entries risks exceeding the AWS per-Security-Group rule
quota (default 60) or the managed prefix list's --max-entries setting.
Nothing has been applied to AWS.

Resolve by EITHER:
  1. Requesting an AWS quota increase for Security Group rules and/or
     prefix list capacity, then re-run with a higher MAX_SG_RULE_ENTRIES, or
  2. Using a curated subset of ranges (documented, deliberate exception),
     rather than truncating this list silently.
EOF
    exit 1
fi

echo "All ${entry_count} entries passed CIDR validation and quota check. Proceeding."

# Look up an existing prefix list by name, or create one sized to fit.
existing_pl_id="$(aws ec2 describe-managed-prefix-lists \
    --filters "Name=prefix-list-name,Values=${PREFIX_LIST_NAME}" \
    --query 'PrefixLists[0].PrefixListId' --output text 2>/dev/null || true)"

if [ -z "${existing_pl_id}" ] || [ "${existing_pl_id}" = "None" ]; then
    echo "Creating managed prefix list '${PREFIX_LIST_NAME}' (MaxEntries=${entry_count})..."
    entries_json="$(printf '%s\n' "${validated_entries[@]}" | jq -R '{Cidr: .}' | jq -s '.')"
    pl_id="$(aws ec2 create-managed-prefix-list \
        --prefix-list-name "${PREFIX_LIST_NAME}" \
        --max-entries "${entry_count}" \
        --address-family IPv4 \
        --entries "${entries_json}" \
        --query 'PrefixList.PrefixListId' --output text)"
else
    pl_id="${existing_pl_id}"
    echo "Reusing existing prefix list ${pl_id}; replacing entries..."
    version="$(aws ec2 describe-managed-prefix-lists \
        --prefix-list-ids "${pl_id}" \
        --query 'PrefixLists[0].Version' --output text)"
    entries_json="$(printf '%s\n' "${validated_entries[@]}" | jq -R '{Cidr: .}' | jq -s '.')"
    aws ec2 modify-managed-prefix-list \
        --prefix-list-id "${pl_id}" \
        --current-version "${version}" \
        --add-entries "${entries_json}" >/dev/null
fi

echo "Prefix list ID: ${pl_id}"

echo "Adding ingress rule on port 3306 to ${SG_ID} referencing ${pl_id}..."
aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --ip-permissions "IpProtocol=tcp,FromPort=3306,ToPort=3306,PrefixListIds=[{PrefixListId=${pl_id}}]"

echo "Done. Entries applied: ${entry_count}. SG: ${SG_ID}. Prefix list: ${pl_id}."
echo "Remember to run scripts/sg-revoke-actions.sh after the demo."
