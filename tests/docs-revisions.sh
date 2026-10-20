#!/usr/bin/env bash
# Local smoke checks of the actual inline Bash; no GitHub calls or API doubles.
# shellcheck disable=SC2016 # Literal shell expressions are intentional assertions.
set -euo pipefail
workflow=$(realpath "$(dirname "$0")/../.github/workflows/docs-revisions.yml")
root=$(mktemp -d /tmp/docs-revisions-smoke.XXXXXX)
trap 'rm -rf "$root"' EXIT
export RUNNER_TEMP=$root
sed -n '/# Effective push scope/,/# Resolve released version/p' "$workflow" > "$root/scope"
printf 'echo eligible\n' >> "$root/scope"
sed -n '/# Select revision/,/# Package candidate/p' "$workflow" > "$root/select"
printf 'printf "%%s|%%s\\n" "$highest" "$matching"\n' >> "$root/select"
sed -n '/# Package candidate/,/# Only new uploads/p' "$workflow" > "$root/package"
sed -n '/^          repo=/,$p' "$workflow" > "$root/publish"
bash -n "$root/scope"; bash -n "$root/publish"
cd "$root"; git init -qb main; git config core.autocrlf false
commit() {
  git add docs
  [[ ! -f implementation.java ]] || git add implementation.java
  git -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
  GITHUB_SHA=$(git rev-parse HEAD); export GITHUB_SHA
}
mkdir docs; mkdir docs/site
printf '# Guide\n' > docs/site/index.md; printf -- '- index.md\n' > docs/site/nav.yml
commit; export BEFORE=$GITHUB_SHA
echo correction >> docs/site/index.md; commit
test "$(bash -euo pipefail "$root/scope")" == eligible
echo code > implementation.java; commit
test -z "$(bash -euo pipefail "$root/scope")"
export BEFORE=$GITHUB_SHA; echo follow-up >> docs/site/index.md; commit
test "$(bash -euo pipefail "$root/scope")" == eligible
echo 'ok: effective docs-only vs mixed pushes; no historical/bootstrap policy'

label="docs-source-sha=$GITHUB_SHA;software-tag-sha=$(git rev-parse HEAD^)"; export label
export assets='[{"name":"docs-site.tar.gz","label":"historical","state":"uploaded"},
  {"name":"docs-site-r2.tar.gz","label":"historical","state":"uploaded"},
  {"name":"docs-site-r10.tar.gz","label":"historical","state":"uploaded"}]'
test "$(bash -euo pipefail "$root/select")" == '10|'
good=$assets
for mutation in '. += [.[1]]' '.[1].name="docs-site-r01.tar.gz"' \
  '.[1].label=$label | .[2].label=$label' '.[1].label=($label+";conflict")'; do
  assets=$(jq --arg label "$label" "$mutation" <<< "$good")
  if bash -euo pipefail "$root/select" > /dev/null 2>&1; then exit 1; fi
done
assets=$(jq --arg label "$label" '.[2].label=$label' <<< "$good")
test "$(bash -euo pipefail "$root/select")" == '10|docs-site-r10.tar.gz'
echo 'ok: numeric gaps, duplicate/conflicting assets and source-labelled retry selection'

export highest=10 matching=''
bash -euo pipefail "$root/package"; cp "$root/docs-site-r11.tar.gz" "$root/first"
touch docs/site/index.md; chmod g+w docs/site/index.md
bash -euo pipefail "$root/package"; cmp "$root/first" "$root/docs-site-r11.tar.gz"
echo 'ok: deterministic tar/gzip bytes'

# Static recovery check: staleness/latest gates apply only to new uploads.
gate=$(sed -n '/# Only new uploads/,/^          fi/p' "$workflow")
grep -Fq 'if [[ -z "$matching" ]]; then' <<< "$gate"
grep -Fq 'heads/main' <<< "$gate"; grep -Fq 'releases/latest' <<< "$gate"
tail=$(sed -n '/^          asset=/,$p' "$workflow")
if grep -Eq 'heads/main|releases/latest|exit|\bif\b' <<< "$tail"; then exit 1; fi
grep -Fq 'cmp "$archive"' <<< "$tail"
test "$(grep -c 'docs-release-published' <<< "$tail")" == 1
echo 'ok: verification and dispatch remain outside the stale/new-upload gate'
