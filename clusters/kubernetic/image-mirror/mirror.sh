#!/bin/sh
# prepare: (aws-cli) create missing ECR repos, write an ECR login token
# copy:    (crane)   mirror each image in images.txt
set -eu
REG=${REG:-774305584254.dkr.ecr.us-east-1.amazonaws.com}
PREFIX=${PREFIX:-poc-e2e}
LIST=${LIST:-/config/images.txt}
PASSWORD_FILE=${PASSWORD_FILE:-/shared/ecr-password}

entries() { grep -v '^[[:space:]]*#' "$LIST" | grep -v '^[[:space:]]*$'; }

prepare() {
  entries | while read -r name _; do
    aws ecr describe-repositories --repository-names "$PREFIX/$name" >/dev/null 2>&1 ||
      { aws ecr create-repository --repository-name "$PREFIX/$name" \
          --image-tag-mutability IMMUTABLE \
          --image-scanning-configuration scanOnPush=true >/dev/null
        echo "created repo $PREFIX/$name"; }
  done
  aws ecr get-login-password > "$PASSWORD_FILE"
}

# copy_tag <src@digest> <dst:tag> <digest>: push unless the tag already holds this digest
copy_tag() {
  have=$(crane digest "$2" 2>/dev/null || true)
  if [ -z "$have" ]; then crane copy "$1" "$2"
  elif [ "$have" != "$3" ]; then echo "  FAIL $2 already exists with $have (want $3)"; return 1
  fi
}

copy() {
  [ -s "$PASSWORD_FILE" ] && crane auth login "$REG" -u AWS --password-stdin < "$PASSWORD_FILE"
  fail=0
  tmp=$(mktemp)
  entries > "$tmp"
  while read -r name src ver plats; do
    dst=$REG/$PREFIX/$name
    echo "== $name $ver ($src)"
    case "$ver" in *latest*) echo "  FAIL version contains 'latest'"; fail=1; continue;; esac
    if crane digest "$dst:$ver" >/dev/null 2>&1; then echo "  skip: $dst:$ver already published"; continue; fi
    # Resolve every platform first so a missing one pushes nothing.
    ok=1; pairs=""; children=""
    for p in $(echo "$plats" | tr , ' '); do
      d=$(crane digest --platform "$p" "$src" 2>/dev/null) || { echo "  FAIL $src has no $p"; ok=0; break; }
      pairs="$pairs $(echo "${p#*/}" | tr / -)=$d"
    done
    if [ $ok = 1 ]; then
      for pair in $pairs; do
        arch=${pair%%=*}; d=${pair#*=}
        copy_tag "$src@$d" "$dst:${ver}_$arch" "$d" || { ok=0; break; }
        echo "  $dst:${ver}_$arch -> $d"
        children="$children -m $dst@$d"
      done
    fi
    if [ $ok = 1 ]; then
      # shellcheck disable=SC2086
      crane index append $children -t "$dst:$ver"
      echo "  published $dst:$ver ($plats)"
    else
      fail=1
    fi
  done < "$tmp"
  exit $fail
}

"$1"
