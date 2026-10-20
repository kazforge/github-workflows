# Publish documentation

Keep guides in `docs/site/` and the version in `.release-please-manifest.json`.
Set `RELEASE_APP_CLIENT_ID` as a repository variable and
`RELEASE_APP_PRIVATE_KEY` as a secret.
The App needs Contents-write on that repository and same-owner `jsonapi-docs`.
Pin `<FULL_COMMIT_SHA>` to a reviewed shared commit. Do not add a caller-level lock.

## Software releases

Replace the existing `docs-publish` job with this caller after Maven Central
publication succeeds. `release-tag` selects the tag whose `docs-site.tar.gz` is published.

```yaml
  docs-publish:
    needs: [release-please, publish]
    if: needs.publish.result == 'success'
    permissions:
      contents: read
    uses: kazforge/github-workflows/.github/workflows/publish-docs.yml@<FULL_COMMIT_SHA>
    with:
      release-tag: ${{ needs.release-please.outputs.tag_name }}
      app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

## Docs-only updates

Omit `release-tag` to append `docs-site-rN.tar.gz` to the manifest's latest published
software release. Add this workflow in Core or Spring; mixed pushes are skipped.

```yaml
on:
  push:
    branches: [main]
    paths: ['docs/site/**']
permissions:
  contents: read
jobs:
  docs:
    uses: kazforge/github-workflows/.github/workflows/publish-docs.yml@<FULL_COMMIT_SHA>
    with:
      app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```
