# Shared documentation revision publisher

Append docs-only corrections to an existing software release without rebuilding
software or replacing its original `docs-site.tar.gz`. Core and Spring use the
same workflow; product reviews own compatibility with the released software.

Required: `app-client-id`, explicit `app-private-key` secret and caller
`contents: read`. The App needs Contents-write on the product and `jsonapi-docs`
under the same owner; its token is limited to those two repositories.

Use this caller as `.github/workflows/docs-revisions.yml` in either product:

```yaml
on:
  push:
    branches: [main]
    paths: ['docs/site/**', '.github/workflows/docs-revisions.yml']
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

Pin a reviewed full SHA. The shared script is checked out at the defining job's
immutable SHA, separately from the triggering product commit (GitHub.com only).
Merge only the new caller file for automatic first-install reconciliation; caller
updates/reintroductions do not reopen it. Deploy the Portal revision consumer first.

The manifest version must identify the latest published stable release, with a
unique uploaded original and exact `docs-source-sha=…;software-tag-sha=…` labels.
Sources must follow the software tag, remain on main and follow numeric revision
order; a post-tag original is valid. New docs and unpublished docs-affecting merges
must be docs-only. Guides require `index.md`, `nav.yml` and no symlinks/submodules.

Revisions append above the highest verified number; gaps are allowed. Historical
assets get metadata/ancestry checks, not archive reconstruction. Only the candidate
upload/retry gets downloaded by ID and byte-compared to its deterministic archive.
Two jobs preserve the release publisher's `docs-REPOSITORY-TAG` lock. Stale runs
cannot upload, but verified uploads always dispatch, even after main advances.
Dispatch retries are at-least-once; the Portal must be idempotent. Conflicting or
partial assets fail closed and require investigation, never automatic replacement.

Rollback means a reviewed docs revert published as the next revision. Never replace
assets or move tags. The lock coordinates cooperating publishers, not manual edits;
GitHub cannot atomically check main and upload. No product pipelines are migrated.

Validate locally: `bash tests/docs-revisions.sh`, `bash -n scripts/docs-revisions.sh`
and `actionlint .github/workflows/docs-revisions.yml` (when installed).
Actionlint 1.7.12 does not yet recognize the documented `job.workflow_*` contexts;
ignore only those property diagnostics, not other expression errors.
