# Container builds (Kaniko on EKS Auto Mode)

Flux applies everything in this folder to the `builds` namespace on the
`kubernetic` cluster.

| File | Purpose |
|------|---------|
| `namespace.yaml` | `builds` namespace (Pod Security `baseline`), `kaniko` ServiceAccount, ECR docker config |
| `example-build.yaml` | Template CronJob that builds a Dockerfile from git and pushes it to ECR |

Kaniko image: [`ghcr.io/osscontainertools/kaniko`](https://github.com/osscontainertools/kaniko),
a maintained fork. Google's original kaniko was archived in June 2025. The
image includes `docker-credential-ecr-login`, so ECR auth comes from EKS Pod
Identity, which EKS Auto Mode has built in. No registry password is stored.

## 1. AWS side (one time)

```sh
ACCOUNT_ID=123456789012
REGION=us-east-1
CLUSTER=kubernetic

# ECR repos: one for the image, one for the layer cache
aws ecr create-repository --region $REGION --repository-name myapp
aws ecr create-repository --region $REGION --repository-name myapp-cache

# IAM role that Pod Identity can assume
aws iam create-role --role-name kaniko-builds \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "pods.eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }'
aws iam attach-role-policy --role-name kaniko-builds \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

# Bind the role to builds/kaniko
aws eks create-pod-identity-association --region $REGION \
  --cluster-name $CLUSTER --namespace builds --service-account kaniko \
  --role-arn arn:aws:iam::$ACCOUNT_ID:role/kaniko-builds
```

`AmazonEC2ContainerRegistryPowerUser` covers push and pull on every repo in the
account. Swap it for a custom policy scoped to specific repos if you want it tighter.

## 2. Fill in the placeholders

Replace `CHANGE-ME-ACCOUNT_ID` / `CHANGE-ME-REGION` in `namespace.yaml`, then
in your build file set `--context`, `--destination` and `--cache-repo`.

## 3. Add a build

1. Copy `example-build.yaml` to `build-<app>.yaml`.
2. Rename the CronJob, set the args, set `suspend: false` and pick a `schedule`.
3. Change the `nodeSelector` arch to `arm64` if you want a Graviton image.
4. Commit. Flux will create it.

## 4. Private source repos (optional)

Create a `git-credentials` Secret in `builds` with `username` / `password`
keys (password = GitHub PAT with repo read). Keep it out of this repo, e.g.
SOPS-encrypted in your secrets repo or via External Secrets.

## 5. Run / watch a build

```sh
kubectl -n builds create job --from=cronjob/build-<app> build-<app>-$(date +%s)
kubectl -n builds logs -f job/build-<app>-<id>
```

## 6. Use the image

EKS Auto Mode nodes can pull from ECR in the same account out of the box, so
just reference `<account>.dkr.ecr.<region>.amazonaws.com/<app>:latest`.
