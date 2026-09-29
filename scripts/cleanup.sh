#!/usr/bin/env bash
# Removes everything deploy.sh created: function (with its revisions and endpoints), table, both
# buckets including every object version, the execution role, and the two log groups. Same
# environment conventions as deploy.sh.
set -uo pipefail

cd "$(dirname "$0")/.."
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_PAGER=""
AWS_CLI="${AWS_CLI:-aws}"
aws() { command ${AWS_CLI} "$@"; }
FN="${FN:-lambda-web-shortener}"
TABLE="${TABLE:-short-links}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CODE_BUCKET="${FN}-code-${ACCOUNT}"
QR_BUCKET="${FN}-qr-${ACCOUNT}"
ROLE="${FN}-role"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

log "Web Function ${FN} (deletes its endpoints and revisions)"
aws lambda-web delete-web-function --function-name "$FN" && aws lambda-web wait web-function-deleted --function-name "$FN"

log "DynamoDB table ${TABLE}"
aws dynamodb delete-table --table-name "$TABLE" --query TableDescription.TableStatus --output text

for b in "$CODE_BUCKET" "$QR_BUCKET"; do
  log "Bucket ${b}: every version and delete marker, then the bucket"
  aws s3api list-object-versions --bucket "$b" \
    --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}' \
    --output json > /tmp/delete-"$b".json
  if python3 -c "import json,sys; sys.exit(0 if json.load(open('/tmp/delete-$b.json')).get('Objects') else 1)"; then
    aws s3api delete-objects --bucket "$b" --delete file:///tmp/delete-"$b".json --query 'length(Deleted)' --output text
  fi
  aws s3api delete-bucket --bucket "$b"
done

log "Execution role ${ROLE}"
aws iam delete-role-policy --role-name "$ROLE" --policy-name shortener-access
aws iam delete-role --role-name "$ROLE"

log "Log groups (Lambda may recreate them for ~30 s after the function is gone)"
for g in "/aws/lambda/web/${FN}" "/aws/lambda/web/${FN}.local"; do aws logs delete-log-group --log-group-name "$g" 2>/dev/null; done
sleep 45
for g in $(aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/web/${FN}" --query 'logGroups[].logGroupName' --output text); do
  aws logs delete-log-group --log-group-name "$g" && echo "re-deleted ${g}"
done

rm -f .endpoint-url

log "Remaining"
aws lambda-web list-web-functions --query 'functions[].functionName' --output text
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/web/${FN}" --query 'logGroups[].logGroupName' --output text
