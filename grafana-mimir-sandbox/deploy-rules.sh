#!/usr/bin/env bash
# Does what the GitLab pipeline does: lint -> diff -> sync the rule files to Mimir.
#   ./deploy-rules.sh before     deploy today's rules
#   ./deploy-rules.sh after      deploy the merge request version
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${1:?usage: ./deploy-rules.sh before|after}
DIR="demo/$VERSION/mimir-rules"
[ -d "$DIR" ] || { echo "Folder $DIR not found"; exit 1; }
TENANT=$(grep -E '^TENANT_ID=' .env | cut -d= -f2)
FILES=$(cd "$DIR" && find . -name '*.yaml' | sort | sed 's|^\./|/rules-src/|')
MT="docker compose run --rm -v $PWD/$DIR:/rules-src mimirtool"

echo "=== 1. lint ===";  $MT rules lint --dry-run $FILES
echo "=== 2. diff ===";  $MT rules diff --address=http://mimir:9009 --id="$TENANT" $FILES || true
echo "=== 3. sync ===";  $MT rules sync --address=http://mimir:9009 --id="$TENANT" $FILES
echo "=== rules now in Mimir ==="; $MT rules list --address=http://mimir:9009 --id="$TENANT"
