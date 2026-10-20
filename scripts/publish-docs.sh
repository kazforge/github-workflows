#!/usr/bin/env bash
set -euo pipefail

phase=${1:?prepare or publish}
if [[ "$phase" == prepare && -z "${RELEASE_TAG:-}" ]]; then
  [[ "$BEFORE" =~ ^[a-f0-9]{40}$ && ! "$BEFORE" =~ ^0+$ ]] || exit 0
  git diff --no-renames --name-only "$BEFORE" "$GITHUB_SHA" > "$RUNNER_TEMP/paths"
  [[ -s "$RUNNER_TEMP/paths" ]] && ! grep -qv '^docs/site/' "$RUNNER_TEMP/paths" || exit 0
fi
version="v$(jq -er '.["."]' .release-please-manifest.json)"
tag=${RELEASE_TAG:-$version}
[[ "$tag" == "$version" && "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
if [[ "$phase" == prepare ]]; then
  echo "tag=$tag" >> "$GITHUB_OUTPUT"
  exit 0
fi
[[ "$phase" == publish ]]

# Resolve the expected release, never falling back to an older version.
repo=$GITHUB_REPOSITORY
release=$(gh api "repos/$repo/releases/tags/$tag")
jq -e '.draft == false and .prerelease == false and .published_at != null' <<< "$release" > /dev/null
software=$(git rev-parse "refs/tags/$tag^{commit}")
source=$(git rev-parse HEAD)
[[ "$(gh api "repos/$repo/commits/$tag" --jq .sha)" == "$software" ]]
endpoint="repos/$repo/releases/$(jq -r .id <<< "$release")/assets?per_page=100"
assets=$(gh api --paginate "$endpoint" --jq '.[]' | jq -s .)
label="docs-source-sha=$source;software-tag-sha=$software"
name=docs-site.tar.gz

if [[ -n "${RELEASE_TAG:-}" ]]; then
  [[ "$source" == "$software" ]] # Originals for new releases come from the software tag.
else
  # A valid original is the docs-ready marker, including legacy post-tag originals.
  [[ "$source" == "$GITHUB_SHA" ]]
  original=$(jq -ce '[.[] | select(.name == "docs-site.tar.gz")] | select(length == 1) | .[0]
    | select(.state == "uploaded" and .size > 0)' <<< "$assets")
  provenance='^docs-source-sha=([a-f0-9]{40});software-tag-sha=([a-f0-9]{40})$'
  [[ "$(jq -r .label <<< "$original")" =~ $provenance ]]
  original_source=${BASH_REMATCH[1]}
  [[ "${BASH_REMATCH[2]}" == "$software" ]]
  git merge-base --is-ancestor "$software" "$original_source"
  git merge-base --is-ancestor "$original_source" "$source"
  [[ "$original_source" != "$source" ]] || exit 0
  highest=0 matching=''
  declare -A seen=()
  while IFS=$'\t' read -r asset_name existing_label state; do
    [[ "$asset_name" == docs-site.tar.gz ]] && continue
    [[ "$asset_name" =~ ^docs-site-r([1-9][0-9]*)\.tar\.gz$ ]]
    number=${BASH_REMATCH[1]}
    [[ ${#number} -lt 19 && -z "${seen[$number]+x}" && "$state" == uploaded ]]
    seen[$number]=1
    if ((number > highest)); then highest=$number; fi
    if [[ "$existing_label" == "docs-source-sha=$source;"* ]]; then
      [[ "$existing_label" == "$label" && -z "$matching" ]]
      matching=$asset_name
    fi
  done < <(jq -r '.[] | select(.name | startswith("docs-site")) | [.name, (.label // ""), .state] | @tsv' <<< "$assets")
  [[ -n "$matching" || "$highest" != 999999999999999999 ]]
  name=${matching:-docs-site-r$((highest + 1)).tar.gz}
fi

# One packaging, upload, verification and notification path for both modes.
[[ -f docs/site/index.md ]]
git ls-tree -r HEAD:docs/site > "$RUNNER_TEMP/docs-tree"
if grep -qEv '^100(644|755) blob ' "$RUNNER_TEMP/docs-tree"; then exit 1; fi
archive="$RUNNER_TEMP/$name"
tar -C docs/site --format=gnu --sort=name --mtime=@0 --owner=0 --group=0 \
  --numeric-owner --mode='u+rwX,go+rX,go-w' -cf - . | gzip -n > "$archive"
candidate=$(jq -c --arg name "$name" '[.[] | select(.name == $name)]' <<< "$assets")
count=$(jq length <<< "$candidate")
[[ "$count" -lt 2 ]]
if [[ "$count" == 0 ]]; then
  if [[ -z "${RELEASE_TAG:-}" ]]; then
    [[ "$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)" == "$source" ]] || exit 0
    [[ "$(gh api "repos/$repo/releases/latest" --jq .tag_name)" == "$tag" ]]
  fi
  gh release upload "$tag" "$archive#$label" --repo "$repo"
  candidate=$(gh api --paginate "$endpoint" --jq '.[]' | jq -s --arg name "$name" '[.[] | select(.name == $name)]')
fi
asset=$(jq -ce --arg label "$label" 'select(length == 1) | .[0]
  | select(.label == $label and .state == "uploaded" and .size > 0)' <<< "$candidate")
gh api "repos/$repo/releases/assets/$(jq -r .id <<< "$asset")" \
  -H 'Accept: application/octet-stream' > "$RUNNER_TEMP/published.tar.gz"
cmp "$archive" "$RUNNER_TEMP/published.tar.gz"
# Verified existing uploads must notify even if main or the latest release advanced.
gh api --method POST "repos/${repo%/*}/jsonapi-docs/dispatches" -f event_type=docs-release-published
