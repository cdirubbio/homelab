# Container builds (Kaniko)

Flux applies everything in this folder to the `builds` namespace.

| File | Purpose |
|------|---------|
| `namespace.yaml` | `builds` namespace (Pod Security `baseline`) + `kaniko` ServiceAccount |
| `example-build.yaml` | Template CronJob that builds a Dockerfile from git and pushes it to a registry |

Kaniko image: [`ghcr.io/osscontainertools/kaniko`](https://github.com/osscontainertools/kaniko),
a maintained fork. Google's original kaniko was archived in June 2025.

## 1. Secrets (in the SOPS repo, not here)

Add these to `cdirubbio-cicd/flux-infra` under `secrets/homelab/`, encrypted with SOPS.

**Registry push credentials** (required). For GHCR, use a classic PAT with `write:packages`:

```sh
kubectl create secret docker-registry registry-credentials \
  --namespace builds \
  --docker-server=ghcr.io \
  --docker-username=cdirubbio \
  --docker-password=<PAT> \
  --dry-run=client -o yaml > registry-credentials.yaml
sops --encrypt --in-place registry-credentials.yaml
```

**Git credentials** (only for private source repos):

```sh
kubectl create secret generic git-credentials \
  --namespace builds \
  --from-literal=username=cdirubbio \
  --from-literal=password=<PAT with repo read> \
  --dry-run=client -o yaml > git-credentials.yaml
sops --encrypt --in-place git-credentials.yaml
```

## 2. Add a build

1. Copy `example-build.yaml` to `build-<app>.yaml`.
2. Rename the CronJob and set `--context`, `--destination` and `--cache-repo`.
3. Set `suspend: false` and pick a `schedule`.
4. Commit. Flux will create it.

## 3. Run / watch a build

```sh
kubectl -n builds create job --from=cronjob/build-<app> build-<app>-$(date +%s)
kubectl -n builds logs -f job/build-<app>-<id>
```

## 4. Use the image

Reference `ghcr.io/cdirubbio/<app>:latest` from a Deployment. If the GHCR
package is private, add an `imagePullSecret` in that workload's namespace.
