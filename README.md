# Documentation revisions

Append docs-only corrections to an existing software release using the same App,
tar/gzip, immutable upload, verification and dispatch pattern as product release
jobs. Product reviews own compatibility with the released software; the Portal
owns comprehensive verification of historical documentation assets.

Required input: `app-client-id`. Required explicit secret: `app-private-key`.
The caller needs `contents: read`; the App needs Contents-write on the product and
`jsonapi-docs` under the same owner. Its token is limited to those repositories.

Use this caller in Core or Spring, pinned to a reviewed full commit SHA:

```yaml
on:
  push:
    branches: [main]
    paths: ['docs/site/**']
permissions:
  contents: read
jobs:
  docs:
    uses: kazforge/github-workflows/.github/workflows/docs-revisions.yml@<FULL_COMMIT_SHA> # vX.Y.Z
    with:
      app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

Only nonempty, effective docs-only pushes qualify. The manifest identifies the
latest stable published release; a unique uploaded original with exact source/tag
provenance is mandatory, including valid post-tag originals. Revisions use the
highest numeric suffix plus one (gaps allowed), never replace assets, and verify
the candidate's labels and downloaded bytes before payload-free Portal dispatch.
Retries reuse the source-labelled asset and notify even if main/release advances.
The native per-release lock matches product publishing. Tags/assets must not be
manually mutated; ref checks and uploads cannot be atomic. Roll back through a
reviewed docs revert published as a new revision, not asset replacement.

**PO approval required — contract change:** automatic bootstrap and unpublished
history analysis are removed; historical provenance verification is delegated to
the Portal. Eligibility covers only the triggering push; product review must
account for all documentation included in the snapshot.
After the Portal consumer is deployed and validated, install the pinned caller,
then merge a small, meaningful, reviewed docs-only follow-up correcting/confirming
the pending released-version guides. Pilot Spring v0.1.0, verify its revision and
Portal build, then repeat for Core v0.4.0. Caller installation alone publishes
nothing. No permanent manual trigger is provided; this procedure is proposed,
not executed.

Local checks: `bash tests/docs-revisions.sh`, ShellCheck and actionlint. Smoke tests
exercise local scope/selection/packaging and check retry/dispatch control flow;
real GitHub queue, token and dispatch integration still needs an approved pilot.
