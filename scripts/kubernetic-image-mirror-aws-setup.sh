#!/usr/bin/env bash
# One-time AWS setup for clusters/kubernetic/image-mirror. Safe to re-run.
# Creates IAM role image-mirror (Pod Identity, this cluster only) that can
# create and push poc-e2e/* ECR repos, and binds it to builds/image-mirror.
# Also creates ECR pull-through cache rules (no upstream credentials needed):
#   ecr-public/* -> public.ecr.aws, k8s/* -> registry.k8s.io
set -euo pipefail
ACCOUNT_ID=774305584254
REGION=us-east-1
CLUSTER=kubernetic
ROLE=image-mirror
export AWS_REGION=$REGION

# --- Pull-through cache rules --------------------------------------------------
ensure_ptc() { # prefix upstream
  aws ecr describe-pull-through-cache-rules --ecr-repository-prefixes "$1" >/dev/null 2>&1 ||
    aws ecr create-pull-through-cache-rule --ecr-repository-prefix "$1" \
      --upstream-registry-url "$2" >/dev/null
  echo "pull-through cache ok: $1 -> $2"
}
ensure_ptc ecr-public public.ecr.aws
ensure_ptc k8s registry.k8s.io

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
    --description "image-mirror Job on $CLUSTER (builds/image-mirror via Pod Identity)" \
    --assume-role-policy-document "$TRUST" >/dev/null
fi

aws iam put-role-policy --role-name "$ROLE" --policy-name ecr-poc-e2e --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"Auth","Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Sid":"Repos","Effect":"Allow","Action":[
   "ecr:CreateRepository","ecr:DescribeRepositories","ecr:DescribeImages","ecr:ListImages",
   "ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:BatchCheckLayerAvailability",
   "ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage"],
  "Resource":"arn:aws:ecr:$REGION:$ACCOUNT_ID:repository/poc-e2e/*"},
 {"Sid":"PullThroughCache","Effect":"Allow","Action":[
   "ecr:CreateRepository","ecr:BatchImportUpstreamImage",
   "ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:BatchCheckLayerAvailability"],
  "Resource":["arn:aws:ecr:$REGION:$ACCOUNT_ID:repository/ecr-public/*",
              "arn:aws:ecr:$REGION:$ACCOUNT_ID:repository/k8s/*"]}]}
JSON
)"
echo "role ok: $ROLE"

EXISTING=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
  --namespace builds --service-account image-mirror --query 'associations[0].associationId' --output text)
if [ "$EXISTING" = "None" ]; then
  aws eks create-pod-identity-association --cluster-name "$CLUSTER" \
    --namespace builds --service-account image-mirror \
    --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$ROLE" >/dev/null
fi
echo "pod identity ok: builds/image-mirror -> $ROLE"
