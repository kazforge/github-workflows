# Publish documentation

One workflow with two modes: supply `release-tag` to publish `docs-site.tar.gz`
from that software tag, or omit it to append `docs-site-rN.tar.gz` after an
effective docs-only push to main, using the root Release Please manifest version.

Required input: `app-client-id`; explicit secret: `app-private-key`. Caller token:
`contents: read`. The App token has Contents-write only on the product and
same-owner `jsonapi-docs`. The script comes from `job.workflow_repository` at
`job.workflow_sha` (GitHub.com); no extra ref input or inherited secrets.

## Consumer examples — not applied

In **both Core and Spring**, replace the entire `release.yml` `docs-publish` job
(runner, steps and concurrency) with this caller. Keep release/Maven jobs unchanged;
the successful Central job is the release-mode gate. Pin a reviewed full shared SHA.

```yaml
  docs-publish:
    needs: [release-please, publish]
    if: needs.publish.result == 'success'
    permissions:
      contents: read
    uses: kazforge/github-workflows/.github/workflows/publish-docs.yml@<FULL_COMMIT_SHA> # vX.Y.Z
    with:
      release-tag: ${{ needs.release-please.outputs.tag_name }}
      app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

Replace each Docs Revision draft PR's publisher with this separate
`.github/workflows/docs-revisions.yml`. No installation trigger or caller-level lock:

```yaml
on:
  push:
    branches: [main]
    paths: ['docs/site/**']
permissions:
  contents: read
jobs:
  docs:
    uses: kazforge/github-workflows/.github/workflows/publish-docs.yml@<FULL_COMMIT_SHA> # vX.Y.Z
    with:
      app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

## Safety and policy approval

Tag, manifest and live software SHA must agree. Both modes require a stable
published GitHub release; docs updates additionally require a valid original
(post-tag sources supported), current main and latest release for new uploads.
Incomplete expected releases never fall back. Numeric gaps are allowed.
Both modes share deterministic regular-file-only packaging (`index.md` required),
the existing `docs-REPOSITORY-TAG` lock and candidate label/byte verification before
payload-free `docs-release-published`. Retries notify even after main/release
advances; conflicts/partial candidates fail closed. Never replace legacy originals.
Rollback is a reviewed docs revert/new revision. Manual tag/asset mutation is
outside the lock; ref-check/upload is not atomic.

**PO approval:** scope expands to replacing release docs publishing; the entry point
becomes `publish-docs.yml` with optional `release-tag`. Bootstrap/history scanners
remain removed. Portal owns final asset validation; product reviews own full-snapshot
software compatibility. Builds/Maven/other CI stay local; migrations need approval.

## Validation and integration plan

Local: `bash -n scripts/publish-docs.sh`, ShellCheck and actionlint (1.7.12 needs only
the four documented `job.workflow_*` property diagnostics ignored). No test harness.

Before production, approve this unexecuted plan using a disposable product, isolated
App and `jsonapi-docs` receiver under a **separate owner**, never production credentials:

1. Pin this SHA. Create a synthetic manifest/tag/published release after a simulated
   Central success. Release mode must produce the original, exact SHA labels/bytes
   and a payload-free event; rerun must reuse the asset and repeat dispatch.
2. Make a docs-only push: verify `r1`, unchanged original and event. Confirm mixed
   pushes skip and missing-original/incomplete-new-release cases never update an
   older release. Check numeric gaps and both tag-aligned/post-tag original sources.
3. Interrupt after upload acceptance, then rerun; no duplicate. Fail dispatch, advance
   main and subsequently the manifest/release, then rerun the old job: verify bytes
   and recovered dispatch without upload. Check conflicting labels/bytes fail closed.
4. Queue both callers for the same tag; verify serialization and stale-new-run skips.
   Retain asset IDs/digests and receiver events as evidence.

After evidence and Portal deployment/validation, approve migration. Pilot Spring,
then Core; reconcile pending v0.1.0/v0.4.0 guides through a meaningful reviewed
docs-only follow-up after caller installation, reviewing the full snapshot. No
bootstrap/manual trigger, production rollout or consumer edits were performed.
