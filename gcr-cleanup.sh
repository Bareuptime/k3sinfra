#!/bin/bash
set -euo pipefail

ORG="Bareuptime"
PACKAGE="backend"
KEEP=3
INTERVAL=5   # seconds between runs (3600 = 1 hour)

while true; do
  echo "⏰ $(date '+%Y-%m-%d %H:%M:%S') — Starting GHCR cleanup for $ORG/$PACKAGE"

  VERSIONS_JSON=$(gh api -H "Accept: application/vnd.github+json" \
    /orgs/$ORG/packages/container/$PACKAGE/versions)

  TAGGED_IDS=($(echo "$VERSIONS_JSON" | jq -r \
    '.[] | select(.metadata.container.tags | length > 0) | .id'))
  UNTAGGED_IDS=($(echo "$VERSIONS_JSON" | jq -r \
    '.[] | select(.metadata.container.tags | length == 0) | .id'))

  TOTAL_TAGGED=${#TAGGED_IDS[@]}
  TOTAL_UNTAGGED=${#UNTAGGED_IDS[@]}

  echo "🔖 Found $TOTAL_TAGGED tagged and $TOTAL_UNTAGGED untagged versions."

  # Delete untagged in parallel
  if (( TOTAL_UNTAGGED > 0 )); then
    echo "🗑️  Deleting all untagged versions in parallel..."
    printf "%s\n" "${UNTAGGED_IDS[@]}" | xargs -I{} -P 40 bash -c '
      echo "  → Deleting untagged version {}"
      gh api --method DELETE -H "Accept: application/vnd.github+json" \
        /orgs/Bareuptime/packages/container/backend/versions/{}
    '
  else
    echo "✅ No untagged versions found."
  fi

#   # Keep only the latest N tagged
#   if (( TOTAL_TAGGED > KEEP )); then
#     echo "🗂️  Keeping $KEEP tagged versions, deleting older ones..."
#     printf "%s\n" "${TAGGED_IDS[@]:$KEEP}" | xargs -I{} -P 5 bash -c '
#       echo "  → Deleting old tagged version {}"
#       gh api --method DELETE -H "Accept: application/vnd.github+json" \
#         /orgs/Bareuptime/packages/container/backend/versions/{}
#     '
#   else
#     echo "✅ $TOTAL_TAGGED tagged versions found, nothing to delete."
#   fi

  echo "🎯 Cleanup complete at $(date '+%H:%M:%S')."
  echo "🕒 Sleeping for $INTERVAL seconds..."
  echo "---------------------------------------------"
  sleep "$INTERVAL"
done
