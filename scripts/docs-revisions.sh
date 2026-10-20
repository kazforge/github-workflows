#!/usr/bin/env bash
set -euo pipefail

fail() { echo "$*" >&2; exit 1; }
docs_only() {
  ((${#paths[@]})) || return 1
  for path in "${paths[@]}"; do [[ "$path" == docs/site/* ]] || return 1; done
}
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/docs-revisions.XXXXXX")
trap 'rm -rf "$work"' EXIT
[[ "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]] || fail 'Wrong triggering checkout'

if [[ "${1:?prepare or publish}" == prepare ]]; then
  [[ "$BEFORE" =~ ^[a-f0-9]{40}$ && ! "$BEFORE" =~ ^0+$ ]] || exit 0
  git merge-base --is-ancestor "$BEFORE" HEAD
  git diff --no-renames --name-only -z "$BEFORE" HEAD > "$work/paths"
  mapfile -d '' -t paths < "$work/paths"
  scope=docs
  if ! docs_only; then
    caller=.github/workflows/docs-revisions.yml
    [[ "${#paths[@]}" == 1 && "${paths[0]}" == "$caller" ]] || exit 0
    [[ -z "$(git log -1 --format=%H "$BEFORE" -- "$caller")" ]] || exit 0
    scope=bootstrap
  fi
  tag="v$(jq -er '.["."] | select(type == "string")' .release-please-manifest.json)"
  [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Invalid release version'
  printf 'tag=%s\nmode=%s\n' "$tag" "$scope" >> "$GITHUB_OUTPUT"
  exit 0
fi
[[ "$1" == publish ]] || fail 'Expected prepare or publish'

tag=$DOCS_TAG
repo=$GITHUB_REPOSITORY
release=$(gh api "repos/$repo/releases/tags/$tag")
jq -e --arg tag "$tag" '.tag_name == $tag and .draft == false and .prerelease == false
  and .published_at != null' <<< "$release" > /dev/null
release_id=$(jq -r .id <<< "$release")
software=$(git rev-parse "refs/tags/$tag^{commit}")
object=$(gh api "repos/$repo/git/ref/tags/$tag")
if [[ "$(jq -r .object.type <<< "$object")" == tag ]]; then
  object=$(gh api "repos/$repo/git/tags/$(jq -r .object.sha <<< "$object")")
fi
jq -e --arg sha "$software" '.object.type == "commit" and .object.sha == $sha' <<< "$object" > /dev/null

read_assets() {
  gh api --paginate "repos/$repo/releases/$release_id/assets?per_page=100" \
    --jq '.[] | select(.name | startswith("docs-site"))' | jq -s .
}
read_assets > "$work/assets.json"
jq -r '.[] | [.name, (.label // ""), .state, .size] | @tsv' "$work/assets.json" > "$work/assets"
label_re='^docs-source-sha=([a-f0-9]{40});software-tag-sha=([a-f0-9]{40})$'
declare -A numbers=() sources=()
highest=0 original=0 matching='' latest_source=''
while IFS=$'\t' read -r name label state size; do
  if [[ "$name" == docs-site.tar.gz ]]; then
    number=0; original=$((original + 1))
  else
    [[ "$name" =~ ^docs-site-r([1-9][0-9]*)\.tar\.gz$ ]] || fail 'Malformed docs asset name'
    number=${BASH_REMATCH[1]}
    [[ ${#number} -lt 19 ]] || fail 'Revision exceeds supported integer range'
  fi
  [[ -z "${numbers[$number]+x}" ]] || fail 'Duplicate docs revision'
  numbers[$number]=1
  [[ "$label" =~ $label_re ]] || fail 'Invalid docs provenance label'
  source=${BASH_REMATCH[1]}
  [[ "${BASH_REMATCH[2]}" == "$software" ]] || fail 'Wrong software provenance'
  [[ -z "${sources[$source]+x}" ]] || fail 'Duplicate docs source'
  sources[$source]=1
  [[ "$state" == uploaded && "$size" -gt 0 ]] || fail 'Incomplete docs asset'
  printf '%s\t%s\n' "$number" "$source" >> "$work/sources"
  if ((number >= highest)); then highest=$number; latest_source=$source; fi
  if ((number > 0)) && [[ "$source" == "$GITHUB_SHA" ]]; then matching=$name; fi
done < "$work/assets"
[[ "$original" == 1 ]] || fail 'Missing unique original docs-site.tar.gz'
sort -n "$work/sources" > "$work/ordered"
previous=$software
while read -r number source; do
  git merge-base --is-ancestor "$previous" "$source"
  git merge-base --is-ancestor "$source" refs/remotes/origin/main
  previous=$source
done < "$work/ordered"

if [[ -z "$matching" ]]; then
  [[ "$MODE" != bootstrap || "$highest" == 0 ]] || exit 0
  git diff --quiet "$latest_source" HEAD -- docs/site && exit 0
  [[ "$highest" != 999999999999999999 ]] || fail 'Revision limit reached'
  # Only unpublished docs-affecting effective merges must be docs-only.
  git merge-base --is-ancestor "$latest_source" HEAD || exit 0 # A newer revision superseded this run.
  git rev-list --first-parent "$latest_source..HEAD" > "$work/history"
  while read -r commit; do
    git diff --no-renames --name-only -z "$commit^" "$commit" > "$work/paths"
    mapfile -d '' -t paths < "$work/paths"
    for path in "${paths[@]}"; do
      if [[ "$path" == docs/site/* ]]; then
        docs_only || fail 'Unpublished mixed docs/software change'
        break
      fi
    done
  done < "$work/history"
fi

[[ -f docs/site/index.md && -f docs/site/nav.yml ]] || fail 'Missing index.md or nav.yml'
git ls-tree -r HEAD:docs/site > "$work/tree"
if grep -qEv '^100(644|755) blob ' "$work/tree"; then fail 'Docs contain symlinks or submodules'; fi
name=${matching:-docs-site-r$((highest + 1)).tar.gz}
archive="$work/$name"
tar -C docs/site --format=gnu --sort=name --mtime=@0 --owner=0 --group=0 \
  --numeric-owner --mode='u+rwX,go+rX,go-w' -cf - . | gzip -n > "$archive"
label="docs-source-sha=$GITHUB_SHA;software-tag-sha=$software"

if [[ -z "$matching" ]]; then
  # Staleness prevents new uploads, never notification recovery for an existing one.
  [[ "$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)" == "$GITHUB_SHA" ]] || exit 0
  [[ "$(gh api "repos/$repo/releases/latest" --jq .tag_name)" == "$tag" ]] || fail 'Latest release changed'
  gh release upload "$tag" "$archive#$label" --repo "$repo"
  read_assets > "$work/assets.json"
fi
asset=$(jq -ce --arg name "$name" --arg label "$label" '
  [.[] | select(.name == $name)] | select(length == 1) | .[0]
  | select(.label == $label and .state == "uploaded" and .size > 0)' "$work/assets.json")
gh api "repos/$repo/releases/assets/$(jq -r .id <<< "$asset")" \
  -H 'Accept: application/octet-stream' > "$work/published.tar.gz"
cmp "$archive" "$work/published.tar.gz"
# Payload-free dispatch rebuilds all releases: main/release advancement cannot lose this notification.
gh api --method POST "repos/${repo%/*}/jsonapi-docs/dispatches" -f event_type=docs-release-published
