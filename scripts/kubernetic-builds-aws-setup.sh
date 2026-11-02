#!/usr/bin/env bash
# One-time AWS setup for Kaniko builds on the kubernetic EKS Auto Mode cluster.
# See clusters/kubernetic/builds/README.md. Safe to re-run (skips what exists).
#
# Creates:
#   - ECR repos: subdc/backend, subdc/backend-cache (scan on push, lifecycle rules)
#   - ECR repo ghcr/osscontainertools/kaniko holding a one-time copy of the
#     Kaniko image, so nodes pull it from ECR instead of ghcr.io
#   - IAM role kaniko-builds (Pod Identity trust scoped to this cluster) with
#     push/pull limited to subdc/* repos
#   - Pod Identity association builds/kaniko -> kaniko-builds
#
# Needs: aws CLI (admin in 774305584254), crane.
set -euo pipefail

ACCOUNT_ID=774305584254
REGION=us-east-1
CLUSTER=kubernetic
ROLE=kaniko-builds
REGISTRY=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
KANIKO_SRC=ghcr.io/osscontainertools/kaniko:v1.28.6
KANIKO_REPO=ghcr/osscontainertools/kaniko
export AWS_REGION=$REGION

ensure_repo() { # name
  aws ecr describe-repositories --repository-names "$1" >/dev/null 2>&1 ||
    aws ecr create-repository --repository-name "$1" \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 >/dev/null
  echo "repo ok: $1"
}

# --- ECR ---------------------------------------------------------------------
ensure_repo subdc/backend
ensure_repo subdc/backend-cache
ensure_repo "$KANIKO_REPO"

aws ecr put-lifecycle-policy --repository-name subdc/backend --lifecycle-policy-text \
  '{"rules":[{"rulePriority":1,"description":"expire untagged after 7d","selection":{"tagStatus":"untagged","countType":"sinceImagePushed","countUnit":"days","countNumber":7},"action":{"type":"expire"}}]}' >/dev/null
aws ecr put-lifecycle-policy --repository-name subdc/backend-cache --lifecycle-policy-text \
  '{"rules":[{"rulePriority":1,"description":"expire cache layers after 14d","selection":{"tagStatus":"any","countType":"sinceImagePushed","countUnit":"days","countNumber":14},"action":{"type":"expire"}}]}' >/dev/null
echo "lifecycle policies ok"

# --- One-time copy of the Kaniko image (all architectures) ---------------------
aws ecr get-login-password | crane auth login "$REGISTRY" -u AWS --password-stdin
crane copy "$KANIKO_SRC" "$REGISTRY/$KANIKO_REPO:${KANIKO_SRC##*:}"

# --- IAM role for Pod Identity -----------------------------------------------
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
    --description "Kaniko builds on $CLUSTER (builds/kaniko via Pod Identity)" \
    --assume-role-policy-document "$TRUST" >/dev/null
fi

aws iam put-role-policy --role-name "$ROLE" --policy-name ecr-push-subdc --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"Auth","Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Sid":"PushPull","Effect":"Allow","Action":[
   "ecr:BatchCheckLayerAvailability","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer",
   "ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage",
   "ecr:DescribeImages","ecr:DescribeRepositories","ecr:ListImages"],
  "Resource":"arn:aws:ecr:$REGION:$ACCOUNT_ID:repository/subdc/*"}]}
JSON
)"
echo "role ok: $ROLE"

# --- Pod Identity association (needs the cluster ACTIVE) ------------------------
echo "waiting for $CLUSTER to be ACTIVE..."
aws eks wait cluster-active --name "$CLUSTER"
EXISTING=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
  --namespace builds --service-account kaniko --query 'associations[0].associationId' --output text)
if [ "$EXISTING" = "None" ]; then
  aws eks create-pod-identity-association --cluster-name "$CLUSTER" \
    --namespace builds --service-account kaniko \
    --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$ROLE" >/dev/null
fi
echo "pod identity ok: builds/kaniko -> $ROLE"
