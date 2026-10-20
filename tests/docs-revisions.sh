#!/usr/bin/env bash
# Real Git fixtures plus canned gh command transcripts; no server/API simulator.
# shellcheck disable=SC2016 # GitHub expressions below are intentional literal assertions.
set -euo pipefail
script=$(realpath "$(dirname "$0")/../scripts/docs-revisions.sh")
workflow=$(realpath "$(dirname "$0")/../.github/workflows/docs-revisions.yml")
root=$(mktemp -d /tmp/docs-revisions-tests.XXXXXX)
trap 'rm -rf "$root"' EXIT
mkdir "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
n=$(( $(wc -l < "$FIXTURE/calls") + 1 ))
printf '%s\n' "$*" >> "$FIXTURE/calls"
if [[ "$1" == release ]]; then
  cp "${4%%#*}" "$FIXTURE/upload"
  [[ -z "${AFTER_UPLOAD:-}" ]] || git update-ref refs/remotes/origin/main "$AFTER_UPLOAD"
fi
[[ ! -f "$FIXTURE/$n.fail" ]] || exit 1
cat "$FIXTURE/$n"
STUB
chmod +x "$root/bin/gh"
export PATH="$root/bin:$PATH" GITHUB_REPOSITORY=example/product
export GITHUB_OUTPUT="$root/output" RUNNER_TEMP="$root"
commit() {
  git add -A; git commit -qm fixture
  GITHUB_SHA=$(git rev-parse HEAD); export GITHUB_SHA
  git update-ref refs/remotes/origin/main HEAD
}
new_repo() {
  local directory
  directory=$(mktemp -d "$root/product.XXXXXX"); cd "$directory"
  git init -qb main; git config user.name Test; git config user.email test@example.invalid
  git config core.autocrlf false
  mkdir -p docs/site
  printf '# Released\n' > docs/site/index.md; printf -- '- index.md\n' > docs/site/nav.yml
  printf '{".":"1.0.0"}\n' > .release-please-manifest.json
  commit; software=$GITHUB_SHA; original=$software; git tag v1.0.0
  FIXTURE=$(mktemp -d "$root/transcript.XXXXXX"); export FIXTURE
  export DOCS_TAG=v1.0.0 MODE=docs; unset AFTER_UPLOAD
  : > "$FIXTURE/calls"
}
asset() {
  local name=docs-site.tar.gz
  [[ "$1" == 0 ]] || name="docs-site-r$1.tar.gz"
  jq -n --arg name "$name" --arg source "$2" --arg software "$software" --argjson id "$((100 + $1))" \
    '{id:$id,name:$name,label:("docs-source-sha="+$source+";software-tag-sha="+$software),state:"uploaded",size:1}'
}
transcript() {
  : > "$FIXTURE/calls"
  printf '{"id":7,"tag_name":"v1.0.0","draft":false,"prerelease":false,"published_at":"2026-10-20"}' > "$FIXTURE/1"
  jq -n --arg sha "$software" '{object:{type:"commit",sha:$sha}}' > "$FIXTURE/2"
  asset 0 "$original" > "$FIXTURE/3"
  printf '%s\n' "$GITHUB_SHA" > "$FIXTURE/4"; printf 'v1.0.0\n' > "$FIXTURE/5"
  : > "$FIXTURE/6"; { asset 0 "$original"; asset 1 "$GITHUB_SHA"; } > "$FIXTURE/7"
  ln -sf "$FIXTURE/upload" "$FIXTURE/8"; : > "$FIXTURE/9"
}
prepare() { : > "$GITHUB_OUTPUT"; BEFORE=$1 bash "$script" prepare; }
reject() { if bash "$script" publish > "$root/rejected" 2>&1; then echo 'Expected rejection' >&2; exit 1; fi; }

new_repo; before=$GITHUB_SHA
echo correction >> docs/site/index.md; commit; prepare "$before"
grep -qx mode=docs "$GITHUB_OUTPUT"
echo code > implementation.java; echo mixed >> docs/site/index.md
commit; prepare "$before"; test ! -s "$GITHUB_OUTPUT"
transcript; reject; grep -q 'mixed docs/software' "$root/rejected"
echo next >> docs/site/index.md; commit; transcript; reject # Later docs cannot hide the mixed commit.
before=$GITHUB_SHA; mkdir -p .github/workflows; echo caller > .github/workflows/docs-revisions.yml
commit; prepare "$before"; grep -qx mode=bootstrap "$GITHUB_OUTPUT"
before=$GITHUB_SHA; echo update >> .github/workflows/docs-revisions.yml
commit; prepare "$before"; test ! -s "$GITHUB_OUTPUT"
echo 'ok: docs-only, mixed history and first-install scope'

for post_tag in no yes; do
  new_repo
  if [[ "$post_tag" == yes ]]; then echo legacy >> docs/site/index.md; commit; original=$GITHUB_SHA; fi
  echo maintenance > implementation.java; commit # Compatibility is product-reviewed, not guessed from paths.
  echo correction >> docs/site/index.md; commit
  mkdir -p .github/workflows; echo caller > .github/workflows/docs-revisions.yml; commit
  export MODE=bootstrap; transcript; bash "$script" publish
  grep -q 'event_type=docs-release-published' "$FIXTURE/calls"
  cp "$FIXTURE/7" "$FIXTURE/3"; ln -sf "$FIXTURE/upload" "$FIXTURE/4"; : > "$FIXTURE/5"
  : > "$FIXTURE/calls"; bash "$script" publish; test "$(wc -l < "$FIXTURE/calls")" == 5
  echo later >> docs/site/index.md; commit
  : > "$FIXTURE/calls"; bash "$script" publish; test "$(wc -l < "$FIXTURE/calls")" == 3
done
echo 'ok: tag-aligned and post-tag originals reconcile without product branches'

new_repo; echo correction >> docs/site/index.md; commit; transcript
cp "$FIXTURE/3" "$root/original"
for mutation in '.label="invalid"' '.label|=sub("software-tag-sha=.*";"software-tag-sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")' \
                '.name="docs-site-r01.tar.gz"' '.label|=sub("docs-source-sha=[^;]+";"docs-source-sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")'; do
  jq "$mutation" "$root/original" > "$FIXTURE/3"; : > "$FIXTURE/calls"; reject
done
cat "$root/original" "$root/original" > "$FIXTURE/3"; : > "$FIXTURE/calls"; reject
{ cat "$root/original"; asset 1 "$software"; } > "$FIXTURE/3"
: > "$FIXTURE/calls"; reject
echo 'ok: invalid provenance, malformed names and duplicate assets fail closed'

transcript; bash "$script" publish; cp "$FIXTURE/upload" "$root/first.tar.gz"
touch docs/site/index.md; chmod g+w docs/site/index.md
transcript; bash "$script" publish; cmp "$root/first.tar.gz" "$FIXTURE/upload"
echo 'ok: archive bytes ignore filesystem timestamps and group-write permissions'

new_repo; echo two >> docs/site/index.md; commit; r2=$GITHUB_SHA
echo ten >> docs/site/index.md; commit; r10=$GITHUB_SHA
echo eleven >> docs/site/index.md; commit; transcript
{ asset 10 "$r10"; asset 0 "$original"; asset 2 "$r2"; } > "$FIXTURE/3"
{ cat "$FIXTURE/3"; asset 11 "$GITHUB_SHA"; } > "$FIXTURE/7"
bash "$script" publish; grep -q 'docs-site-r11.tar.gz' "$FIXTURE/calls"
echo 'ok: numeric ordering and gaps (r2, r10 -> r11)'

transcript; printf '%040d\n' 0 > "$FIXTURE/4"; bash "$script" publish
test "$(wc -l < "$FIXTURE/calls")" == 4 # No upload for a stale run.
grep -Fq 'group: docs-${{ github.repository }}-${{ needs.prepare.outputs.tag }}' "$workflow"
grep -Fq 'cancel-in-progress: false' "$workflow"
test "$(grep -Fc 'repository: ${{ job.workflow_repository }}' "$workflow")" == 2
test "$(grep -Fc 'ref: ${{ job.workflow_sha }}' "$workflow")" == 2
grep -Fq "github.event_name == 'push' && github.ref == 'refs/heads/main'" "$workflow"
grep -Fq '!github.event.deleted && !github.event.forced' "$workflow"
echo 'ok: native release lock, immutable shared checkout and stale-upload suppression'

run=$GITHUB_SHA; echo maintenance >> implementation.java; commit; export AFTER_UPLOAD=$GITHUB_SHA
git switch -q --detach "$run"; export GITHUB_SHA=$run
transcript; : > "$FIXTURE/9.fail"; reject # main advances during upload, then dispatch fails.
test "$(git rev-parse refs/remotes/origin/main)" == "$AFTER_UPLOAD"
test "$(wc -l < "$FIXTURE/calls")" == 9
cp "$FIXTURE/7" "$FIXTURE/3"; rm "$FIXTURE/9.fail"
ln -sf "$FIXTURE/upload" "$FIXTURE/4"; : > "$FIXTURE/5"
for _retry in 1 2; do
  : > "$FIXTURE/calls"; bash "$script" publish
  test "$(wc -l < "$FIXTURE/calls")" == 5
  test "$(grep -c 'event_type=docs-release-published' "$FIXTURE/calls")" == 1
  if grep -q 'release upload' "$FIXTURE/calls"; then exit 1; fi
done
rm "$FIXTURE/4"; echo conflicting > "$FIXTURE/4"
: > "$FIXTURE/calls"; reject
if grep -q 'POST' "$FIXTURE/calls"; then exit 1; fi
echo 'ok: advanced-main retry, dispatch recovery, duplicates and byte conflicts'

new_repo; ln -s index.md docs/site/link; commit; transcript; reject
grep -q 'symlinks or submodules' "$root/rejected"
echo 'ok: symlinks are never packaged'
