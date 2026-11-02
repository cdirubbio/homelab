# Container builds (Kaniko on EKS Auto Mode)

Flux applies everything in this folder to the `builds` namespace on the
`kubernetic` cluster.

| File | Purpose |
|------|---------|
| `namespace.yaml` | `builds` namespace (Pod Security `baseline`), `kaniko` ServiceAccount, ECR docker config |
| `example-build.yaml` | Template CronJob (suspended) that builds a Dockerfile from git and pushes it to ECR |
| `build-subdc-backend.yaml` | Builds `cdirubbio/subdc` `backend/src` -> ECR `subdc/backend:latest`, every minute |

Kaniko image: [`ghcr.io/osscontainertools/kaniko`](https://github.com/osscontainertools/kaniko),
a maintained fork, copied once into ECR (`ghcr/osscontainertools/kaniko`) so
nodes never pull from ghcr.io. An ECR pull-through cache for ghcr.io would need
a GitHub token in Secrets Manager, so a one-time `crane copy` is used instead;
re-run the setup script with a new `KANIKO_SRC` tag to upgrade. Google's original kaniko was archived in June 2025. The
image includes `docker-credential-ecr-login`, so ECR auth comes from EKS Pod
Identity, which EKS Auto Mode has built in. No registry password is stored.

## 1. AWS side (one time)

```sh
./scripts/kubernetic-builds-aws-setup.sh
```

Idempotent. Creates the ECR repos (`subdc/backend`, `subdc/backend-cache`,
`ghcr/osscontainertools/kaniko`) with scan-on-push and lifecycle rules, copies
the Kaniko image, creates the `kaniko-builds` IAM role (Pod Identity trust
limited to this cluster, push/pull limited to `subdc/*` repos) and binds it to
`builds/kaniko` with a Pod Identity association. For images outside `subdc/*`,
widen the `ecr-push-subdc` inline policy.

## 2. Fill in the placeholders

Account/region are already filled in for 774305584254 / us-east-1. In a new
build file set `--context`, `--destination` and `--cache-repo`.

## 3. Add a build

1. Copy `example-build.yaml` to `build-<app>.yaml`.
2. Rename the CronJob, set the args, set `suspend: false` and pick a `schedule`.
3. Change the `nodeSelector` arch to `arm64` if you want a Graviton image. The
   built-in Auto Mode `general-purpose` NodePool is amd64 only, so this also
   needs a custom NodePool that allows arm64.
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
