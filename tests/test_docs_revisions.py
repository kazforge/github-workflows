"""Exercise the actual inline workflow code using real local Git and an in-memory GitHub.

No Actions, credentials, remote mutations or third-party Python packages are needed.
"""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import textwrap
import types
import unittest
from unittest.mock import patch


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/docs-revisions.yml"
YAML = WORKFLOW.read_text()
PUBLISH = textwrap.dedent(YAML.split("shell: python3 {0}\n        run: |\n", 1)[1])
PREPARE = textwrap.dedent(YAML.split("shell: bash\n        run: |\n", 1)[1].split("\n  publish:", 1)[0])
publisher = types.ModuleType("publisher")
exec(compile(PUBLISH, str(WORKFLOW), "exec"), publisher.__dict__)


class PublisherTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory(prefix="docs-revisions-test-", dir="/tmp"))
        self.root = Path(directory)
        self.enterContext(contextlib.chdir(self.root))
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.software = self.commit({
            "docs/site/index.md": "# Released guide\n",
            "docs/site/nav.yml": "- index.md\n",
            "module/src/main/Api.java": "released API\n",
            ".release-please-manifest.json": '{".": "1.0.0"}',
        })
        self.git("tag", "v1.0.0")
        self.repo = "example/product"
        self.release = {"id": 10, "tag_name": "v1.0.0", "draft": False,
                        "prerelease": False, "published_at": "2026-10-01T00:00:00Z"}
        self.remote_assets = []
        self.downloads = {}
        self.uploads = self.dispatches = 0
        self.dispatch_failure = False
        self.main_checks = 0
        self.stale_on_check = None
        self.tag_object = {"type": "commit", "sha": self.software}
        self.add_asset(0, self.software)
        self.head = self.software
        self.env = self.enterContext(patch.dict(os.environ, {
            "GITHUB_REPOSITORY": self.repo, "GITHUB_SHA": self.head,
            "DOCS_TAG": "v1.0.0", "MODE": "docs",
        }))
        self.enterContext(patch.object(publisher, "gh", side_effect=self.gh))

    def git(self, *args):
        return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL).decode().strip()

    def commit(self, files):
        for name, data in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
        self.git("add", "--", *files)
        self.git("commit", "-qm", "local fixture")
        return self.git("rev-parse", "HEAD")

    def docs(self, text="# Updated released guide\n"):
        self.head = self.commit({"docs/site/index.md": text})
        os.environ["GITHUB_SHA"] = self.head
        return self.head

    def add_asset(self, number, source):
        data = publisher.archive(source)
        asset = {"id": len(self.remote_assets) + 100,
                 "name": f"docs-site-r{number}.tar.gz" if number else "docs-site.tar.gz",
                 "label": f"docs-source-sha={source};software-tag-sha={self.software}",
                 "state": "uploaded", "size": len(data),
                 "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
        self.remote_assets.append(asset)
        self.downloads[asset["id"]] = data
        return asset

    def gh(self, *args):
        if args[:2] == ("release", "upload"):
            self.uploads += 1
            self.assertNotIn("--clobber", args)
            path, label = args[3].split("#")
            data = Path(path).read_bytes()
            asset = {"id": len(self.remote_assets) + 100, "name": Path(path).name,
                     "label": label, "state": "uploaded", "size": len(data),
                     "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
            self.remote_assets.append(asset)
            self.downloads[asset["id"]] = data
            return b""
        self.assertEqual(args[0], "api")
        if "POST" in args:
            self.assertEqual(args, ("api", "--method", "POST", "repos/example/jsonapi-docs/dispatches",
                                    "-f", "event_type=docs-release-published"))
            self.dispatches += 1
            if self.dispatch_failure:
                raise subprocess.CalledProcessError(1, ["gh", *args])
            return b""
        endpoint = args[2] if args[1] == "--paginate" else args[1]
        if "/releases/assets/" in endpoint:
            self.assertIn("Accept: application/octet-stream", args)
            return self.downloads[int(endpoint.rsplit("/", 1)[1])]
        if endpoint.endswith("/assets?per_page=100"):
            return b"\n".join(json.dumps(a).encode() for a in self.remote_assets)
        if endpoint.endswith("/heads/main"):
            self.main_checks += 1
            head = "f" * 40 if self.stale_on_check and self.main_checks >= self.stale_on_check else self.head
            result = {"object": {"sha": head}}
        elif endpoint.endswith("/releases/latest"):
            result = self.release
        elif "/git/ref/tags/" in endpoint:
            result = {"object": self.tag_object}
        elif "/git/tags/" in endpoint:
            result = {"object": {"type": "commit", "sha": self.software}}
        else:
            self.fail(f"Unexpected GitHub call: {args}")
        return json.dumps(result).encode()

    def assert_rejected(self, message=None):
        with self.assertRaises((ValueError, subprocess.CalledProcessError)) as caught:
            publisher.publish()
        if message:
            self.assertIn(message, str(caught.exception))
        self.assertEqual((self.uploads, self.dispatches), (0, 0))

    def prepare(self, before):
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        cli = bin_dir / "gh"
        cli.write_text("#!/bin/sh\nprintf '%s\\n' v1.0.0\n")
        cli.chmod(0o755)
        output = self.root / "output"
        output.write_text("")
        env = dict(os.environ, BEFORE=before, GITHUB_SHA=self.head, GITHUB_OUTPUT=str(output),
                   RUNNER_TEMP=str(self.root), PATH=str(bin_dir) + ":" + os.environ["PATH"])
        result = subprocess.run(["bash", "-c", PREPARE], env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return output.read_text()

    def test_docs_only_publish_and_original_immutable(self):
        original = dict(self.remote_assets[0])
        self.docs()
        publisher.publish()
        self.assertEqual((self.uploads, self.dispatches), (1, 1))
        self.assertEqual(self.remote_assets[0], original)
        self.assertEqual(self.remote_assets[-1]["name"], "docs-site-r1.tar.gz")

    def test_effective_push_scope_and_first_install(self):
        self.docs()
        self.assertIn("mode=docs", self.prepare(self.software))
        self.head = self.commit({"README.md": "mixed"})
        self.assertEqual(self.prepare(self.software), "")
        before = self.head
        self.head = self.commit({".github/workflows/docs-revisions.yml": "caller"})
        self.assertIn("mode=bootstrap", self.prepare(before))
        before = self.head
        self.head = self.commit({".github/workflows/docs-revisions.yml": "changed caller"})
        self.assertEqual(self.prepare(before), "")

    def test_empty_and_new_branch_push_skip(self):
        self.assertEqual(self.prepare(self.head), "")
        self.assertEqual(self.prepare("0" * 40), "")

    def test_deleted_and_reintroduced_caller_is_not_first_install(self):
        caller = ".github/workflows/docs-revisions.yml"
        self.commit({caller: "installed"})
        (self.root / caller).unlink()
        self.git("add", "--", caller)
        self.git("commit", "-qm", "delete caller")
        before = self.git("rev-parse", "HEAD")
        self.head = self.commit({caller: "reintroduced"})
        self.assertEqual(self.prepare(before), "")

    def test_scope_handles_unusual_filenames_and_renames(self):
        self.head = self.commit({"docs/site/topic\nname.md": "docs"})
        self.assertIn("mode=docs", self.prepare(self.software))
        before = self.head
        self.git("mv", "docs/site/index.md", "outside.md")
        self.git("commit", "-qm", "move out of docs")
        self.head = self.git("rev-parse", "HEAD")
        self.assertEqual(self.prepare(before), "")

    def test_mixed_history_cannot_be_hidden_by_later_docs_only_push(self):
        self.commit({"docs/site/index.md": "unreleased documentation", "README.md": "mixed"})
        self.docs()
        self.assert_rejected("mixed")

    def test_bootstrap_equal_or_post_tag_original(self):
        for post_tag in (False, True):
            with self.subTest(post_tag=post_tag):
                self.remote_assets.clear()
                self.downloads.clear()
                original = self.commit({"docs/site/index.md": "original prepared after tag"}) if post_tag else self.software
                self.add_asset(0, original)
                # Product-neutral maintenance does not block reconciliation.
                self.commit({"gradle/wrapper/gradle-wrapper.properties": str(post_tag)})
                self.docs(f"reviewed docs correction {post_tag}")
                self.head = self.commit({".github/workflows/docs-revisions.yml": str(post_tag)})
                os.environ.update(GITHUB_SHA=self.head, MODE="bootstrap")
                publisher.publish()
                self.assertEqual(self.remote_assets[-1]["name"], "docs-site-r1.tar.gz")
        self.assertEqual((self.uploads, self.dispatches), (2, 2))

    def test_bootstrap_rejects_historical_mixed_docs(self):
        os.environ["MODE"] = "bootstrap"
        self.commit({"docs/site/index.md": "mixed", "build.gradle.kts": "mixed"})
        self.docs()
        self.assert_rejected("mixed")

    def test_bootstrap_is_bounded_after_a_prior_revision(self):
        self.add_asset(1, self.docs())
        self.docs("later docs")
        os.environ["MODE"] = "bootstrap"
        publisher.publish()
        self.assertEqual((self.uploads, self.dispatches), (0, 0))

    def test_unchanged_documentation_is_noop(self):
        publisher.publish()
        self.assertEqual((self.uploads, self.dispatches), (0, 0))

    def test_docs_revert_to_published_snapshot_is_noop(self):
        self.docs("temporary docs correction")
        self.docs("# Released guide\n")
        publisher.publish()
        self.assertEqual((self.uploads, self.dispatches), (0, 0))

    def test_stale_run_before_or_after_verification(self):
        self.docs()
        for check in (1, 2):
            with self.subTest(check=check):
                self.main_checks = 0
                self.stale_on_check = check
                publisher.publish()
                self.assertEqual((self.uploads, self.dispatches), (0, 0))

    def test_source_changes_since_software_release_rejected(self):
        self.commit({"module/src/main/Api.java": "unreleased API"})
        self.docs()
        self.assert_rejected("Unreleased software")

    def test_manifest_latest_release_and_tag_must_agree(self):
        self.docs()
        for key, value in (("tag_name", "v2.0.0"), ("draft", True),
                           ("prerelease", True), ("published_at", None)):
            with self.subTest(key=key), patch.dict(self.release, {key: value}):
                self.assert_rejected()
        self.tag_object["sha"] = "a" * 40
        self.assert_rejected("tag moved")

    def test_manifest_mismatch_is_not_an_older_release_fallback(self):
        self.head = self.commit({".release-please-manifest.json": '{".": "2.0.0"}'})
        os.environ["GITHUB_SHA"] = self.head
        self.assert_rejected("Manifest/release mismatch")

    def test_release_change_while_verifying_does_not_upload(self):
        self.docs()
        real_api = publisher.api
        calls = 0

        def api(endpoint):
            nonlocal calls
            if endpoint.endswith("/releases/latest"):
                calls += 1
                if calls == 2:
                    self.release["tag_name"] = "v2.0.0"
            return real_api(endpoint)

        with patch.object(publisher, "api", side_effect=api):
            self.assert_rejected("Latest software release changed")

    def test_external_asset_change_while_verifying_does_not_upload(self):
        self.docs()
        real_gh = self.gh
        calls = 0

        def gh(*args):
            nonlocal calls
            if any("/assets?per_page=" in arg for arg in args):
                calls += 1
                if calls == 2:
                    self.remote_assets[0]["id"] += 1000
            return real_gh(*args)

        with patch.object(publisher, "gh", side_effect=gh):
            self.assert_rejected("Release assets changed")

    def test_stale_after_upload_does_not_dispatch(self):
        self.docs()
        self.stale_on_check = 3
        publisher.publish()
        self.assertEqual((self.uploads, self.dispatches), (1, 0))

    def test_annotated_tag(self):
        self.tag_object = {"type": "tag", "sha": "a" * 40}
        self.docs()
        publisher.publish()
        self.assertEqual(self.uploads, 1)

    def test_missing_or_incomplete_original_rejected(self):
        self.docs()
        with patch.dict(self.remote_assets[0], {"state": "starter"}):
            self.assert_rejected("Incomplete")
        self.remote_assets.clear()
        self.assert_rejected("Missing original")

    def test_malformed_names_and_labels_rejected(self):
        self.docs()
        for name in ("docs-site-r0.tar.gz", "docs-site-r01.tar.gz", "docs-site-rx.tar.gz",
                     "docs-site-r1.zip", "docs-site-r1.tar.gz.bak", "docs-site-other.tar.gz"):
            with self.subTest(name=name), patch.dict(self.remote_assets[0], {"name": name}):
                self.assert_rejected("Malformed")
        for label in (None, "bad", self.remote_assets[0]["label"] + ";extra=x",
                      f"docs-source-sha={self.software};software-tag-sha={'a' * 40}"):
            with self.subTest(label=label), patch.dict(self.remote_assets[0], {"label": label}):
                self.assert_rejected("provenance")

    def test_duplicate_names_or_sources_rejected(self):
        self.docs()
        self.remote_assets.append(dict(self.remote_assets[0]))
        self.assert_rejected("Duplicate docs revision")
        self.remote_assets[-1]["name"] = "docs-site-r1.tar.gz"
        self.assert_rejected("Duplicate docs source")

    def test_unknown_or_off_main_provenance_rejected(self):
        self.docs()
        original = self.remote_assets[0]
        with patch.dict(original, {"label": f"docs-source-sha={'b' * 40};software-tag-sha={self.software}"}):
            self.assert_rejected()
        self.git("checkout", "-qb", "side", self.software)
        side = self.commit({"docs/site/index.md": "side branch"})
        self.add_asset(1, side)
        self.git("checkout", "-q", "main")
        self.assert_rejected()

    def test_numeric_gaps_and_out_of_order_listing(self):
        self.add_asset(2, self.docs("revision two"))
        self.add_asset(10, self.docs("revision ten"))
        self.remote_assets.reverse()
        self.docs("revision eleven")
        publisher.publish()
        self.assertEqual(self.remote_assets[-1]["name"], "docs-site-r11.tar.gz")

    def test_conflicting_numeric_source_order_rejected(self):
        earlier = self.docs("earlier")
        later = self.docs("later")
        self.add_asset(2, later)
        self.add_asset(10, earlier)
        self.assert_rejected()

    def test_retry_and_failed_dispatch_reuse_verified_asset(self):
        self.docs()
        self.dispatch_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            publisher.publish()
        self.dispatch_failure = False
        publisher.publish()
        publisher.publish()
        self.assertEqual((self.uploads, self.dispatches), (1, 3))

    def test_lost_upload_response_is_retryable(self):
        self.docs()
        real_gh = self.gh

        def gh(*args):
            result = real_gh(*args)
            if args[:2] == ("release", "upload"):
                raise subprocess.CalledProcessError(1, ["gh", *args])
            return result

        with patch.object(publisher, "gh", side_effect=gh):
            with self.assertRaises(subprocess.CalledProcessError):
                publisher.publish()
        publisher.publish()
        self.assertEqual((self.uploads, self.dispatches), (1, 1))

    def test_retry_rejects_conflicting_archive_bytes(self):
        asset = self.add_asset(1, self.docs())
        self.downloads[asset["id"]] = b"corrupt archive"
        self.assert_rejected("digest mismatch")
        asset.pop("digest")
        self.assert_rejected("bytes conflict")

    def test_original_content_provenance_is_checked(self):
        original = self.remote_assets[0]
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            info = tarfile.TarInfo("./index.md")
            info.size = 3
            archive.addfile(info, io.BytesIO(b"bad"))
        self.downloads[original["id"]] = buffer.getvalue()
        original.pop("digest")
        self.docs()
        self.assert_rejected("Original archive conflicts")

    def test_archive_determinism_and_symlink_rejection(self):
        first = publisher.archive(self.software)
        (self.root / "docs/site/index.md").chmod(0o777)
        self.assertEqual(publisher.archive(self.software), first)
        link = self.root / "docs/site/link"
        link.symlink_to("/etc/passwd")
        self.git("add", "docs/site/link")
        self.git("commit", "-qm", "local symlink fixture")
        with self.assertRaisesRegex(ValueError, "symlinks"):
            publisher.archive(self.git("rev-parse", "HEAD"))

    def test_merge_is_checked_as_effective_first_parent_change(self):
        self.git("checkout", "-qb", "reviewed-docs")
        self.docs()
        self.git("checkout", "-q", "main")
        self.git("merge", "--no-ff", "-qm", "reviewed docs merge", "reviewed-docs")
        self.head = self.git("rev-parse", "HEAD")
        os.environ["GITHUB_SHA"] = self.head
        publisher.publish()
        self.assertEqual((self.uploads, self.dispatches), (1, 1))

    def test_workflow_lock_and_trust_boundary(self):
        self.assertIn("group: docs-${{ github.repository }}-${{ needs.prepare.outputs.tag }}", YAML)
        self.assertIn("cancel-in-progress: false", YAML)
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/main'", YAML)
        self.assertIn("!github.event.deleted && !github.event.forced", YAML)
        self.assertNotIn("secrets: inherit", YAML)
        self.assertNotIn("pull_request_target", YAML)
        self.assertEqual(YAML.count("permission-contents: write"), 1)
        self.assertNotIn("persist-credentials: true", YAML)


if __name__ == "__main__":
    unittest.main()
