# image-patcher

Automatic CVE patch rebuilds for the `poc-e2e/*` images published by
`../image-mirror`. All state is ECR tags; nothing is written back to git.

| CronJob | When (UTC) | Does |
|---|---|---|
| `image-patch-amd64` | daily 03:17 | For each `<base>` whose current version has critical findings, rebuild `<base>_amd64` with upgraded OS packages and push `<base>-patch.N_amd64` |
| `image-patch-arm64` | daily 03:17 | Same on the `arm64` NodePool (`../nodepools/arm64.yaml`) |
| `image-patch-index` | daily 05:17 | When both `<base>-patch.N_<arch>` children exist and scan with 0 criticals, publish the `<base>-patch.N` index |

"Current version" = the highest published `<base>-patch.N` index, otherwise
`<base>`. Consumers should move to the newest `-patch.N` tag; nothing updates
them automatically yet.

How a patch is built: `FROM <base>_<arch>`, `USER root`, then `apk upgrade`,
`apt-get upgrade`, `dnf upgrade` or `microdnf upgrade` (whichever exists), then
the original `USER`. Images with no shell or package manager (static Go
binaries, busybox) fail the build with a clear message: the fix for those is a
newer upstream version in `../image-mirror/images.txt`.

Gating: a `-patch.N` index is only published with 0 critical findings. If
criticals remain (no fix upstream yet) it logs `BLOCKED`, and the next day's
builds try `-patch.N+1` with whatever packages are newer by then. Tags are never
overwritten.

Scanning: ECR enhanced scanning (Amazon Inspector) with continuous rescans on
`poc-e2e/*`, so CVEs published after an image was pushed are picked up.

## Setup (one time)

```sh
./scripts/kubernetic-image-patcher-aws-setup.sh
```

Registry-wide change: switches ECR scanning from basic to enhanced. Repos that
use basic scan-on-push today are kept on scan-on-push (except `*-cache`).

## Run now

```sh
kubectl -n builds create job --from=cronjob/image-patch-amd64 patch-amd64-$(date +%s)
kubectl -n builds create job --from=cronjob/image-patch-arm64 patch-arm64-$(date +%s)
# once both finish and the new tags have been scanned (a few minutes):
kubectl -n builds create job --from=cronjob/image-patch-index patch-index-$(date +%s)
kubectl -n builds logs -l app.kubernetes.io/name=image-patcher --all-containers --prefix --tail=50
```
