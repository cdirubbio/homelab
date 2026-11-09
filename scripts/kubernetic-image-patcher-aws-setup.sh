#!/usr/bin/env bash
set -euo pipefail
ACCOUNT_ID=774305584254
REGION=us-east-1
CLUSTER=kubernetic
ROLE=image-patcher
REGISTRY=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
KANIKO_SRC=ghcr.io/osscontainertools/kaniko:v1.28.6-debug
export AWS_REGION=$REGION

echo "current registry scanning config:"
aws ecr get-registry-scanning-configuration --query scanningConfiguration --output json
aws inspector2 enable --resource-types ECR >/dev/null
aws inspector2 update-configuration \
  --ecr-configuration rescanDuration=LIFETIME,pullDateRescanDuration=DAYS_180 >/dev/null
KEEP=$(aws ecr describe-repositories --output json | jq -c '[.repositories[]
  | select(.imageScanningConfiguration.scanOnPush and (.repositoryName | startswith("poc-e2e/") | not) and (.repositoryName | endswith("-cache") | not))
  | {filter: .repositoryName, filterType: "WILDCARD"}]')
RULES=$(jq -nc --argjson keep "$KEEP" '[
  {scanFrequency: "CONTINUOUS_SCAN", repositoryFilters: [{filter: "poc-e2e/*", filterType: "WILDCARD"}]}]
  + (if ($keep | length) > 0 then [{scanFrequency: "SCAN_ON_PUSH", repositoryFilters: $keep}] else [] end)')
aws ecr put-registry-scanning-configuration --scan-type ENHANCED --rules "$RULES" >/dev/null
echo "enhanced scanning ok; rules:"; echo "$RULES" | jq .

aws ecr get-login-password | crane auth login "$REGISTRY" -u AWS --password-stdin
crane copy "$KANIKO_SRC" "$REGISTRY/ghcr/osscontainertools/kaniko:${KANIKO_SRC##*:}"

TRUST=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"pods.eks.amazonaws.com"},
 "Action":["sts:AssumeRole","sts:TagSession"],
 "Condition":{"StringEquals":{"aws:SourceAccount":"$ACCOUNT_ID"},
              "ArnEquals":{"aws:SourceArn":"arn:aws:eks:$REGION:$ACCOUNT_ID:cluster/$CLUSTER"}}}]}
JSON
)
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$TRUST"
else
  aws iam create-role --role-name "$ROLE" \
    --description "image-patcher CronJobs on $CLUSTER (builds/image-patcher via Pod Identity)" \
    --assume-role-policy-document "$TRUST" >/dev/null
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name ecr-poc-e2e-patch --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"Global","Effect":"Allow","Action":["ecr:GetAuthorizationToken","ecr:DescribeRepositories"],"Resource":"*"},
 {"Sid":"EnhancedScanFindings","Effect":"Allow","Action":["inspector2:ListFindings","inspector2:ListCoverage"],"Resource":"*"},
 {"Sid":"Repos","Effect":"Allow","Action":[
   "ecr:DescribeImages","ecr:ListImages","ecr:DescribeImageScanFindings",
   "ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:BatchCheckLayerAvailability",
   "ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage"],
  "Resource":"arn:aws:ecr:$REGION:$ACCOUNT_ID:repository/poc-e2e/*"}]}
JSON
)"
echo "role ok: $ROLE"
EXISTING=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
  --namespace builds --service-account image-patcher --query 'associations[0].associationId' --output text)
if [ "$EXISTING" = "None" ]; then
  aws eks create-pod-identity-association --cluster-name "$CLUSTER" \
    --namespace builds --service-account image-patcher \
    --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$ROLE" >/dev/null
fi
echo "pod identity ok: builds/image-patcher -> $ROLE"
