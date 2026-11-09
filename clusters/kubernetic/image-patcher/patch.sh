#!/bin/sh
set -eu
REG=${REG:-774305584254.dkr.ecr.us-east-1.amazonaws.com}
PREFIX=${PREFIX:-poc-e2e}
ARCHES="amd64 arm64"
RETRY_AFTER_SECONDS=${RETRY_AFTER_SECONDS:-$((20 * 3600))}
FORCE_NEW_PATCH=${FORCE_NEW_PATCH:-}
GO_IMAGE=${GO_IMAGE:-public.ecr.aws/docker/library/golang:1.27.3}
SOURCES=${SOURCES:-/config/sources.txt}
WORK=${WORK:-/work}

log() { echo "$*" >&2; }

tools() { [ -n "${SKIP_TOOLS:-}" ] || dnf install -y -q awscli-2 jq >/dev/null; }
repos() { aws ecr describe-repositories --output json |
  jq -r --arg p "$PREFIX/" '.repositories[].repositoryName | select(startswith($p))'; }
tags() { aws ecr list-images --repository-name "$1" --filter tagStatus=TAGGED \
  --query 'imageIds[].imageTag' --output text | tr '\t' '\n' | grep -v '^$' || true; }
bases() { grep -v '_' | grep -v -- '-patch\.' || true; }
has() { grep -qx -- "$2" "$1"; }
max_n() {
  b=$(printf '%s' "$2" | sed 's/[.]/\\./g')
  { grep -E "^${b}-patch\.[0-9]+$3\$" "$1" || true; } |
    sed -E "s/^${b}-patch\.([0-9]+).*/\1/" | sort -n | tail -1 | grep . || echo 0
}
pushed_epoch() { date -d "$(aws ecr describe-images --repository-name "$1" \
  --image-ids imageTag="$2" --query 'imageDetails[0].imagePushedAt' --output text)" +%s; }
criticals() {
  if ! out=$(aws ecr describe-image-scan-findings --repository-name "$1" --image-id imageTag="$2" \
      --output json 2>/tmp/scan-err); then
    log "  scan lookup $1:$2: $(grep -o '([A-Za-z]*Exception)\|(AccessDenied[A-Za-z]*)' /tmp/scan-err | head -1) $(tail -c 200 /tmp/scan-err)"
    echo pending; return
  fi
  printf '%s\n' "$out" | jq -r '
      if (.imageScanStatus.status == "COMPLETE" or .imageScanStatus.status == "ACTIVE") then
        [ (.imageScanFindings.enhancedFindings // [])[], (.imageScanFindings.findings // [])[]
          | select(.severity == "CRITICAL") ] | length
      else "pending" end' 2>/dev/null | grep . || echo pending
}
state() {
  M=$(max_n "$3" "$2" ''); if [ "$M" -gt 0 ]; then CUR="$2-patch.$M"; else CUR=$2; fi
  K=0; for a in $ARCHES; do k=$(max_n "$3" "$2" "_$a"); if [ "$k" -gt "$K" ]; then K=$k; fi; done
}
image_config() {
  m=$(aws ecr batch-get-image --repository-name "$1" --image-ids imageTag="$2" \
    --accepted-media-types application/vnd.oci.image.manifest.v1+json application/vnd.docker.distribution.manifest.v2+json \
    --query 'images[0].imageManifest' --output text)
  d=$(echo "$m" | jq -r .config.digest)
  u=$(aws ecr get-download-url-for-layer --repository-name "$1" --layer-digest "$d" --query downloadUrl --output text)
  curl -sf "$u"
}
source_for() {
  [ -f "$SOURCES" ] || return 0
  grep -v '^[[:space:]]*#' "$SOURCES" | while read -r n v rest; do
    if [ "$n" = "$1" ] && [ "$v" = "$2" ]; then echo "$rest"; fi
  done
}

go_bumps() {
  repo=$1; shift
  for t in "$@"; do
    aws ecr describe-image-scan-findings --repository-name "$repo" --image-id imageTag="$t" \
      --output json 2>/dev/null | jq -r '
        .imageScanFindings.enhancedFindings[]?.packageVulnerabilityDetails.vulnerablePackages[]?
        | select(.packageManager == "GO")
        | select((.fixedInVersion // "NotAvailable") != "NotAvailable")
        | "\(.name) \(.version) \(.fixedInVersion | gsub(" "; ""))"' || true
  done | while read -r mod have fixes; do
    for f in $(echo "$fixes" | tr ',' ' '); do
      f=v${f#v}; have=v${have#v}
      case "$f" in *-*) log "  skip $mod $f (pre-release fix version)"; continue;; esac
      if [ "$(printf '%s\n%s\n' "$have" "$f" | sort -V | tail -1)" = "$f" ] && [ "$f" != "$have" ]; then
        echo "$mod $f"
      fi
    done
  done | sort -k1,1 -k2,2V | {
    last=""; lastv=""
    while read -r mod v; do
      if [ -n "$last" ] && [ "$mod" != "$last" ]; then printf '%s@%s ' "$last" "$lastv"; fi
      last=$mod; lastv=$v
    done
    if [ -n "$last" ]; then printf '%s@%s ' "$last" "$lastv"; fi
  }
}

plan_build() {
  arch=$1; tools; mkdir -p "$WORK"; : > "$WORK/plan"; now=$(date +%s)
  for repo in $(repos); do
    tags "$repo" > /tmp/tags
    for base in $(bases < /tmp/tags); do
      state "$repo" "$base" /tmp/tags
      id="$repo:$base"
      crit=0; pend=0
      for a in $ARCHES; do
        has /tmp/tags "${CUR}_$a" || continue
        c=$(criticals "$repo" "${CUR}_$a")
        if [ "$c" = pending ]; then pend=1; else crit=$((crit + c)); fi
      done
      if [ $pend = 1 ]; then log "wait  $id: scan of $CUR pending"; continue; fi
      if [ $crit = 0 ]; then log "ok    $id: $CUR has no critical findings"; continue; fi
      if [ "$K" -le "$M" ]; then N=$((M + 1))
      elif [ -n "$FORCE_NEW_PATCH" ]; then N=$((K + 1))
      elif ! has /tmp/tags "$base-patch.${K}_$arch"; then N=$K
      else
        missing=0; newest=0
        for a in $ARCHES; do
          t="$base-patch.${K}_$a"
          if has /tmp/tags "$t"; then e=$(pushed_epoch "$repo" "$t"); if [ "$e" -gt $newest ]; then newest=$e; fi
          else missing=1; fi
        done
        if [ $missing = 1 ]; then log "wait  $id: patch.$K waiting for other arch"; continue; fi
        if [ $((now - newest)) -lt $RETRY_AFTER_SECONDS ]; then log "wait  $id: patch.$K waiting for index job"; continue; fi
        N=$((K + 1))
      fi
      name=$(echo "$repo-$base-$N" | tr '/:' '--')
      src=$(source_for "${repo#"$PREFIX"/}" "$base")
      cfgtag="${base}_$arch"
      if ! has /tmp/tags "$cfgtag"; then
        case "$src" in
          ''|*' keep') log "skip  $id: no ${base}_$arch mirrored and no source rebuild onto a new base"; continue;;
        esac
        for a in $ARCHES; do if has /tmp/tags "${base}_$a"; then cfgtag="${base}_$a"; break; fi; done
      fi
      cfg=$(image_config "$repo" "$cfgtag")
      user=$(printf '%s\n' "$cfg" | jq -r '.config.User // ""')
      from="$REG/$repo:${base}_$arch"; how="OS packages"
      mkdir -p "$WORK/$name"
      {
        if [ -n "$src" ]; then
          set -- $src; git=$1 ref=$2 pkg=$3 bin=$4 xflag=$5 newbase=$6
          if [ "$xflag" = - ]; then ld="-s -w"; else ld="-s -w -X $xflag"; fi
          if [ "$newbase" != keep ]; then from=$newbase; fi
          scanned="${CUR}_$arch"
          if [ "$K" -gt "$M" ] && has /tmp/tags "$base-patch.${K}_$arch"; then scanned="$scanned $base-patch.${K}_$arch"; fi
          bumps=$(go_bumps "$repo" $scanned)
          how="OS packages + $bin rebuilt from $git@$ref with ${GO_IMAGE##*:}"
          echo "FROM $GO_IMAGE AS build"
          echo "RUN git init -q /src && cd /src && git remote add origin $git \\"
          echo "    && git fetch -q --depth 1 origin $ref && git checkout -q FETCH_HEAD"
          if [ -n "$bumps" ]; then
            how="$how, go get ${bumps% }"
            echo "ENV GOWORK=off GOFLAGS=-mod=mod"
            echo "ENV BUMPS=\"${bumps% }\""
            cat <<'LOOP'
RUN cd /src && for mv in $BUMPS; do m=${mv%@*}; v=${mv#*@}; \
      have=$(go list -m -f '{{.Version}}' "$m" 2>/dev/null || echo v0.0.0); \
      top=$(printf '%s\n%s\n' "$have" "$v" | sort -V | tail -1); \
      if [ "$top" = "$have" ]; then echo "keep $m $have (>= $v)"; \
      else echo "bump $m $have -> $v"; go get "$m@$v" || exit 1; fi; done
LOOP
          fi
          echo "RUN cd /src && CGO_ENABLED=0 go build -trimpath -ldflags \"$ld\" -o /out$bin $pkg"
        fi
        echo "FROM $from"
        echo "USER root"
        echo 'RUN if command -v apk >/dev/null 2>&1; then apk upgrade --no-cache; \'
        echo '    elif command -v apt-get >/dev/null 2>&1; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade && rm -rf /var/lib/apt/lists/*; \'
        echo '    elif command -v dnf >/dev/null 2>&1; then dnf -y upgrade && dnf clean all; \'
        echo '    elif command -v microdnf >/dev/null 2>&1; then microdnf -y upgrade && microdnf clean all; \'
        echo '    else echo "no package manager in image: cannot patch, bump upstream version instead"; exit 3; fi'
        if [ -n "$src" ]; then
          echo "COPY --from=build /out$bin $bin"
          if [ "$newbase" != keep ]; then
            printf '%s\n' "$cfg" | jq -r '.config
              | (if (.WorkingDir // "") != "" then "WORKDIR \(.WorkingDir)" else empty end),
                (if .Entrypoint then "ENTRYPOINT \(.Entrypoint | tojson)" else empty end),
                (if .Cmd then "CMD \(.Cmd | tojson)" else empty end)'
          fi
        fi
        if [ -n "$user" ]; then echo "USER $user"; fi
      } > "$WORK/$name/Dockerfile"
      echo "$name $REG/$repo:$base-patch.${N}_$arch" >> "$WORK/plan"
      log "build $id: $crit critical in $CUR -> $base-patch.${N}_$arch ($how)"
    done
  done
}

build() {
  arch=$1; fail=0
  [ -s "$WORK/plan" ] || { echo "nothing to build for $arch"; exit 0; }
  while read -r name dest; do
    echo "== $dest"
    if /kaniko/executor --context "dir://$WORK/$name" --dockerfile "$WORK/$name/Dockerfile" \
         --destination "$dest" --cleanup --compressed-caching=false < /dev/null; then
      echo "  pushed $dest"
    else
      echo "  FAIL $dest (see Dockerfile message above; static images cannot be OS-patched)"; fail=1
    fi
  done < "$WORK/plan"
  exit $fail
}

plan_index() {
  tools; mkdir -p "$WORK"; : > "$WORK/index-plan"
  for repo in $(repos); do
    tags "$repo" > /tmp/tags
    for base in $(bases < /tmp/tags); do
      state "$repo" "$base" /tmp/tags
      if [ "$K" -le "$M" ]; then continue; fi
      tag="$base-patch.$K"; ok=1; crit=0
      for a in $ARCHES; do
        has /tmp/tags "${tag}_$a" || { ok=0; break; }
        c=$(criticals "$repo" "${tag}_$a")
        if [ "$c" = pending ]; then ok=0; break; fi
        crit=$((crit + c))
      done
      if [ $ok != 1 ]; then log "wait    $repo:$tag: children or scans not ready"; continue; fi
      cur_crit=0
      for a in $ARCHES; do
        if has /tmp/tags "${CUR}_$a"; then
          c=$(criticals "$repo" "${CUR}_$a"); if [ "$c" != pending ]; then cur_crit=$((cur_crit + c)); fi
        fi
      done
      if [ $crit -gt 0 ] && [ $crit -ge $cur_crit ]; then
        log "BLOCKED $repo:$tag: $crit critical, not fewer than $CUR ($cur_crit); retried tomorrow"; continue
      fi
      echo "$repo $tag" >> "$WORK/index-plan"; log "publish $repo:$tag ($crit critical, $CUR had $cur_crit)"
    done
  done
  aws ecr get-login-password > "$WORK/ecr-password"
}

index() {
  crane auth login "$REG" -u AWS --password-stdin < "$WORK/ecr-password"
  [ -s "$WORK/index-plan" ] || { echo "nothing to publish"; exit 0; }
  while read -r repo tag; do
    m=""; for a in $ARCHES; do m="$m -m $REG/$repo:${tag}_$a"; done
    crane index append $m -t "$REG/$repo:$tag"
    echo "published $REG/$repo:$tag"
  done < "$WORK/index-plan"
}

mode=$1; shift
case "$mode" in
  plan-build) plan_build "$@";; build) build "$@";;
  plan-index) plan_index;;      index) index;;
  *) echo "unknown mode $mode" >&2; exit 2;;
esac
