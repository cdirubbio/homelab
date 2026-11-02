# image-mirror

Mirrors the upstream images listed in `images.txt` into ECR
(`774305584254.dkr.ecr.us-east-1.amazonaws.com/poc-e2e/<name>`) as
versioned multi-arch images:

- `<version>_<arch>` for each platform (e.g. `1.31.6_amd64`, `1.31.6_arm64`)
- `<version>`: multi-arch index pointing at those tagged children

Rules enforced by `mirror.sh`: no tag containing `latest`, every required
platform present upstream, every index child has its own tag, and existing tags
are never overwritten (repos are created IMMUTABLE with scan on push).
Already-published versions are skipped.

Sources: nginx, busybox and agnhost come through ECR pull-through caches
(`ecr-public/*` -> public.ecr.aws, `k8s/*` -> registry.k8s.io), so they never
hit Docker Hub. curl and cyclonus are only on Docker Hub and are pulled
directly (a Docker Hub pull-through cache would need a Docker Hub token in
Secrets Manager). The caches are just the upstream copy; the versioned,
immutable `poc-e2e/*` repos are what you consume.

## Setup (one time)

Creates the pull-through cache rules, the `image-mirror` IAM role and its Pod
Identity association.

```sh
./scripts/kubernetic-image-mirror-aws-setup.sh
```

## Run

Edit `images.txt` and commit; Flux re-runs the Job because the ConfigMap hash
changes. To re-run without a change:

```sh
kubectl -n builds delete job image-mirror && flux reconcile kustomization flux-system
kubectl -n builds logs -f job/image-mirror -c copy
```
