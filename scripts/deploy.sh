#!/usr/bin/env bash
# Deploys the shortener as a Lambda Web Function with nothing but the AWS CLI.
#
# The same script targets AWS or LocalStack; only the CLI in front differs:
#
#   AWS:         AWS_PROFILE=<profile> ./scripts/deploy.sh
#   LocalStack:  AWS_CLI="lstk aws" ./scripts/deploy.sh        # after `lstk start`
#
# Until the lambda-web model ships in the CLI, AWS_DATA_PATH must point at a directory holding
# lambda-web/2025-03-07/{service-2,paginators-1,waiters-2}.json.
set -euo pipefail

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
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

log "Target: account ${ACCOUNT}, region ${AWS_DEFAULT_REGION}, endpoint ${AWS_ENDPOINT_URL:-aws}"
aws lambda-web get-web-account-settings --query accountQuotas --output table

log "Code bucket (versioned) with a read grant for the Lambda service principal"
aws s3api create-bucket --bucket "$CODE_BUCKET" >/dev/null
aws s3api put-bucket-versioning --bucket "$CODE_BUCKET" --versioning-configuration Status=Enabled
sed -e "s/{{CODE_BUCKET}}/${CODE_BUCKET}/g" -e "s/{{ACCOUNT}}/${ACCOUNT}/g" -e "s/{{REGION}}/${AWS_DEFAULT_REGION}/g" -e "s/{{FN}}/${FN}/g" \
  scripts/code-bucket-policy.template.json > /tmp/code-bucket-policy.json
aws s3api put-bucket-policy --bucket "$CODE_BUCKET" --policy file:///tmp/code-bucket-policy.json

log "QR bucket and DynamoDB table"
aws s3api create-bucket --bucket "$QR_BUCKET" >/dev/null
aws dynamodb create-table --table-name "$TABLE" \
  --attribute-definitions AttributeName=slug,AttributeType=S \
  --key-schema AttributeName=slug,KeyType=HASH --billing-mode PAY_PER_REQUEST \
  --query 'TableDescription.TableStatus' --output text
aws dynamodb wait table-exists --table-name "$TABLE"

log "Execution role"
aws iam create-role --role-name "$ROLE" --assume-role-policy-document file://scripts/trust-policy.json --query Role.Arn --output text
sed -e "s/{{QR_BUCKET}}/${QR_BUCKET}/g" -e "s/{{ACCOUNT}}/${ACCOUNT}/g" -e "s/{{REGION}}/${AWS_DEFAULT_REGION}/g" -e "s/{{FN}}/${FN}/g" -e "s/{{TABLE}}/${TABLE}/g" \
  scripts/role-policy.template.json > /tmp/role-policy.json
aws iam put-role-policy --role-name "$ROLE" --policy-name shortener-access --policy-document file:///tmp/role-policy.json

if [[ ! -f function.zip || -n "$(find app/index.js app/package.json app/public -newer function.zip 2>/dev/null)" ]]; then
  log "Package the application (production dependencies only)"
  (cd app && npm install --omit=dev --no-audit --no-fund >/dev/null && rm -f ../function.zip && zip -qr ../function.zip index.js package.json package-lock.json node_modules public)
  unzip -l function.zip | tail -1
else
  log "Package function.zip is up to date"
fi

log "Upload the package and pin its object version"
aws s3 cp function.zip "s3://${CODE_BUCKET}/function.zip" >/dev/null
VERSION_ID="$(aws s3api head-object --bucket "$CODE_BUCKET" --key function.zip --query VersionId --output text)"
echo "versionId: ${VERSION_ID}"

cat > /tmp/revision-config.json <<JSON
{
  "buildConfig": {
    "codeConfig": { "s3Object": { "bucket": "${CODE_BUCKET}", "key": "function.zip", "versionId": "${VERSION_ID}" } },
    "runtimeConfig": { "runtime": "nodejs24.x" }
  },
  "serviceConfig": {
    "executionRoleArn": "${ROLE_ARN}",
    "timeoutSeconds": 30,
    "maxConcurrencyPerEnvironment": 64,
    "environmentVariables": { "LINKS_TABLE": "${TABLE}", "QR_BUCKET": "${QR_BUCKET}" }
  }
}
JSON

log "Create the Web Function, its first revision and a public endpoint in one call"
aws lambda-web create-web-function --function-name "$FN" \
  --revision-config file:///tmp/revision-config.json \
  --endpoint-config file://scripts/endpoint-config.json \
  --query '{function: functionArn, revision: revision.revisionId, domain: endpoint.domainName}' --output table

REV="$(aws lambda-web list-web-function-revisions --function-name "$FN" --query 'revisions[0].revisionId' --output text)"
log "Wait for revision ${REV} and endpoint 'public' to become Active"
aws lambda-web wait web-function-revision-active --function-name "$FN" --revision-id "$REV"
aws lambda-web wait web-function-endpoint-active --function-name "$FN" --endpoint-name public
DOMAIN="$(aws lambda-web get-web-function-endpoint --function-name "$FN" --endpoint-name public --query domainName --output text)"
SCHEME=https; [[ "$DOMAIN" == *localhost.localstack.cloud* ]] && SCHEME=http   # LocalStack's gateway serves the endpoint over plain HTTP too

log "Live at ${SCHEME}://${DOMAIN}/"
echo "${SCHEME}://${DOMAIN}" > .endpoint-url
curl -s -i "${SCHEME}://${DOMAIN}/healthz" | sed -n '1p;/^lambda-web/p;/^{/p'
