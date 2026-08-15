#!/usr/bin/env bash
#
# sg-revoke-actions.sh
#
# Operator-run close-out counterpart to sg-allow-actions.sh. Removes the
# temporary ingress rule (port 3306, sourced from the managed prefix list)
# and deletes the managed prefix list itself. Run this immediately after the
# demo concludes.
#
# Requirements: aws CLI (configured with credentials/region).
#
# Required environment variables:
#   SG_ID              Security Group ID that was modified
#   PREFIX_LIST_NAME    Name of the managed prefix list created by
#                       sg-allow-actions.sh

set -euo pipefail

: "${SG_ID:?SG_ID environment variable is required (target Security Group ID)}"
: "${PREFIX_LIST_NAME:?PREFIX_LIST_NAME environment variable is required}"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }

pl_id="$(aws ec2 describe-managed-prefix-lists \
    --filters "Name=prefix-list-name,Values=${PREFIX_LIST_NAME}" \
    --query 'PrefixLists[0].PrefixListId' --output text 2>/dev/null || true)"

if [ -z "${pl_id}" ] || [ "${pl_id}" = "None" ]; then
    echo "No managed prefix list named '${PREFIX_LIST_NAME}' found — nothing to revoke."
    exit 0
fi

echo "Revoking ingress rule on ${SG_ID} referencing prefix list ${pl_id}..."
aws ec2 revoke-security-group-ingress \
    --group-id "${SG_ID}" \
    --ip-permissions "IpProtocol=tcp,FromPort=3306,ToPort=3306,PrefixListIds=[{PrefixListId=${pl_id}}]" \
    || echo "WARNING: revoke-security-group-ingress failed (rule may already be gone) — continuing to delete prefix list."

echo "Deleting managed prefix list ${pl_id}..."
aws ec2 delete-managed-prefix-list --prefix-list-id "${pl_id}"

echo "Done. Ingress rule removed and prefix list ${pl_id} deleted."
echo "Remember to rotate RDS_PASSWORD in GitHub Secrets after the demo."
