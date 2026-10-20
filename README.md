# KazForge shared workflows

`docs-revisions.yml` appends documentation-only corrections to an existing software
release. It never builds software, changes tags, replaces assets or creates releases.
There is one implementation for Core and Spring; their Gradle/release pipelines stay local.

## Caller contract

- Input `app-client-id` (required string): the existing release App client ID.
- Secret `app-private-key` (required): that App's private key; pass it explicitly,
  never with `secrets: inherit`.
- Caller `GITHUB_TOKEN`: `contents: read`. The App must be installed on the product
  and `jsonapi-docs` in the same owner. Its short-lived token is narrowed to those
  two repositories and **Contents: write** only (asset upload and dispatch).
- Invoke only for pushes to `main`, from the product-owned caller path shown below.
  The shared workflow independently rejects other events, refs and forced/deleted pushes.
- The root Release Please manifest's `"."` version must match GitHub's latest stable,
  published release and its immutable `vMAJOR.MINOR.PATCH` tag. A unique uploaded
  `docs-site.tar.gz` with verified provenance is the release's docs-ready marker;
  an incomplete latest release fails rather than falling back to an older release.
- Product guides live in `docs/site/`, with regular files only. Revisions require
  `index.md` and `nav.yml`; legacy originals need not have navigation manifests.

Save this **identical caller in Core and Spring** as `.github/workflows/docs-revisions.yml`:

```yaml
name: Documentation revisions
on:
  push:
    branches: [main]
    paths:
      - docs/site/**
      - .github/workflows/docs-revisions.yml
permissions:
  contents: read
jobs:
  docs:
    uses: kazforge/github-workflows/.github/workflows/docs-revisions.yml@<FULL_40_CHARACTER_COMMIT_SHA> # vX.Y.Z
    with:
      app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

Replace the placeholder with a reviewed, immutable **full commit SHA**, not `main`
or a floating tag. The version comment identifies that shared-workflow version for
reviewed upgrades (and Renovate); it is not a product version. No shared version has
been published by this implementation.

For automatic first-install reconciliation, merge **only this new caller file**.
It must never have existed in the caller's history. Updates or delete/re-add cycles
do not reopen reconciliation. Do not activate either caller until the Portal's
revision consumer is merged, deployed and validated; pilot Spring before Core.

## Publication rules

Normal pushes must have a nonempty effective diff confined to `docs/site/**`.
Bootstrap uses exactly the same validation, except its triggering diff is the new
caller file. Each docs-affecting first-parent change since the original docs source
must itself be docs-only, including effective merge diffs. A later docs-only push
cannot conceal an earlier mixed change. Separate maintenance commits are allowed.
Bootstrap stops after an existing revision unless retrying its own publication.

Both current products keep software under `**/src/**` and `examples/`. Changes there
relative to the software tag block publication until a software release; build
configuration and dependency-only maintenance does not. This layout is a deliberate adoption
assumption, not a universal software detector. Review must still ensure prose
describes the released API/dependencies: neither ancestry nor a path check can
prove semantic compatibility.

Every docs asset must have exactly this label:

```text
docs-source-sha=<40 lowercase hex>;software-tag-sha=<40 lowercase hex>
```

The software SHA must equal the live, resolved release tag. Sources must descend
from that tag and be ancestors of the run's main commit. Original sources may be
**newer than the tag**, supporting Core's existing original without a version
exception. Revision sources must follow the original and each other in numeric
order. Missing originals, malformed `docs-site*` names/labels, duplicate numbers or
sources, incomplete uploads and conflicting contents fail closed.

Original contents are verified against their source without extracting the archive
(legacy tar permission bits are allowed). Every revision's downloaded bytes must
match a deterministic archive of its source. Downloads use verified asset IDs and
check GitHub's digest when present. Archives use Git blobs, normalized file modes,
GNU tar ordering/ownership/time and `gzip -n`; product code is never executed.

The next name is `docs-site-rN.tar.gz`, one above the highest verified **numeric**
revision; gaps are allowed. Originals and prior revisions are never overwritten.
Unchanged docs are a no-op. Retries reuse an identical verified revision and resend
the payload-free `docs-release-published` dispatch to `jsonapi-docs`. Dispatch is
at-least-once, not exactly-once; its consumer must be idempotent. A partial upload
or conflicting asset fails for operator investigation, never automatic deletion.

## Concurrency and limits

Two jobs are necessary: `prepare` resolves the tag before `publish` acquires native
job concurrency `docs-${{ github.repository }}-${tag}`, with cancellation disabled.
This is exactly the product release docs publisher's group. Do not add a competing
caller-level lock. Main, tag, release and assets are checked inside the lock and
again before writes. Stale runs skip; retries after a lost upload response or failed
dispatch verify the prior upload rather than creating another revision.

GitHub does not offer an atomic main-ref-check plus asset-upload transaction. A
push immediately after the last check can leave an older, still valid immutable
snapshot; the post-upload check suppresses its dispatch if it became stale. Native
concurrency coordinates cooperating workflows, not manual asset/tag mutations;
detected conflicts fail closed. Keep tags and published assets protected by process.

## Local validation and KISS review

```sh
python3 -B -m unittest discover -s tests -v
actionlint .github/workflows/docs-revisions.yml  # when installed
git diff --check
```

Tests execute the actual inline Bash/Python, with real scratch Git histories and
mocked GitHub reads/writes; no testing dependencies or live publishing are needed.
They cover mixed/hidden changes, both bootstrap provenance shapes, source guards,
invalid and duplicate assets, numeric gaps, deterministic bytes, merge history,
release/asset races, stale runs, lost upload responses and dispatch retries.
Actual GitHub queue ordering, installation permissions and Portal deployment still
need an explicitly approved pilot.

Read-only validation also passed against Core `v0.4.0` at
`f1f4f0d58a517b5eceb4ccbd160bab8fff584b9a` and Spring `v0.1.0` at
`baa9cdbf0d18189fecbc67f6f86f4eed06f82e28`, including their real original archive
contents and provenance. Uploads and dispatches were intercepted locally: each
selected `r1`, and a duplicate run reused it without another upload. No product or
Portal repository was modified.

KISS review: no product branches, build commands, version constants, composite
actions, checkout of a second implementation repository, configurable path lists
or custom locking/retry framework. The inline Python remains because structured
asset validation, Git provenance and byte verification are clearer and testable
without a large Bash/jq parser. The second job is needed solely for the dynamic
release lock. Those are the security/concurrency costs, not extension points.
