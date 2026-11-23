"""Focused downloads-site checks: python3 tests/pages.py (standard library only)."""

from html.parser import HTMLParser
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest
from zipfile import ZipFile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("guildqueue_pages", ROOT / "site/build.py")
pages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pages)


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.current = None
        self.articles, self.links, self.ids = {}, [], []
        self.scripts = 0
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if tag == "article":
            self.current = {"downloads": [], "bullets": 0}
            self.articles[attrs["data-version"]] = self.current
        if tag == "a":
            self.links.append(attrs["href"])
            if self.current is not None and "download" in attrs:
                self.current["downloads"].append(attrs)
        if tag == "li" and self.current is not None:
            self.current["bullets"] += 1
        if tag == "script":
            self.scripts += 1

    def handle_endtag(self, tag):
        if tag == "article":
            self.current = None


class DownloadsSiteTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="guildqueue-pages-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        (self.root / "site").mkdir()
        for relative in ("CHANGELOG.md", "site/releases.json", "site/template.html"):
            shutil.copyfile(ROOT / relative, self.root / relative)
        self.entries = json.loads((self.root / "site/releases.json").read_text())
        for entry in self.entries:
            filename = "GuildQueue-" + entry["version"] + ".zip"
            shutil.copyfile(ROOT / filename, self.root / filename)

    def manifest(self, entries):
        (self.root / "site/releases.json").write_text(json.dumps(entries))

    def test_every_catalog_version_has_a_heading_download_and_exact_bulleted_notes(self):
        self.assertFalse((self.root / "README.md").exists())
        outputs = pages.generated_files(self.root)
        text = outputs[self.root / "docs/index.html"].decode()
        page = Page(text)
        releases = pages.load_releases(self.root)
        self.assertEqual(list(page.articles), [release["version"] for release in releases])
        for release in releases:
            with self.subTest(version=release["version"]):
                self.assertIn("<h3>v" + release["version"] + "</h3>", text)
                article = page.articles[release["version"]]
                self.assertEqual(article["bullets"], len(release["notes"]))
                self.assertEqual(len(article["downloads"]), 1)
                self.assertEqual(article["downloads"][0]["href"], release["download"])
                self.assertEqual(article["downloads"][0]["download"], release["filename"])
                self.assertEqual(outputs[self.root / "docs" / release["download"]],
                                 (self.root / release["filename"]).read_bytes())
                for note in release["notes"]:
                    self.assertIn("<li>" + pages.inline_markdown(note) + "</li>", text)
        self.assertEqual(page.scripts, 0)
        self.assertEqual(len(page.ids), len(set(page.ids)))
        for link in page.links:
            self.assertTrue(link.startswith(("#", "downloads/")), link)
            if link.startswith("#"):
                self.assertIn(link[1:], page.ids)
        self.assertEqual(outputs[self.root / "docs/.nojekyll"], b"")

    def test_previews_are_labeled_and_never_replace_the_latest_released_primary_download(self):
        text = pages.generated_files(self.root)[self.root / "docs/index.html"].decode()
        releases = pages.load_releases(self.root)
        primary = next(release for release in releases if release["status"] == "released")
        self.assertIn('href="' + primary["download"] + '" download>Download release · v' + primary["version"], text)
        self.assertEqual(text.count("Upcoming · Preview build"), sum(r["status"] == "preview" for r in releases))
        for entry in self.entries:
            entry["status"] = "released"
        self.manifest(self.entries)
        promoted = pages.generated_files(self.root)[self.root / "docs/index.html"].decode()
        self.assertIn('download>Download release · v' + releases[0]["version"], promoted)
        self.assertNotIn("Not yet released.", promoted)

    def test_build_and_check_detect_html_and_zip_drift_without_writing_in_check_mode(self):
        count, changed = pages.build(self.root)
        expected = len(self.entries) + 2
        self.assertEqual((count, changed), (expected, expected))
        self.assertEqual(pages.build(self.root, check=True), (expected, 0))
        page = self.root / "docs/index.html"
        original = page.read_bytes()
        changelog = self.root / "CHANGELOG.md"
        changelog.write_text(re.sub(r"(^### v" + re.escape(self.entries[0]["version"]) + r"[^\n]*\n)",
                                    r"\1\n- Extra test change.\n", changelog.read_text(), count=1, flags=re.MULTILINE))
        with self.assertRaisesRegex(ValueError, "out of date"):
            pages.build(self.root, check=True)
        self.assertEqual(page.read_bytes(), original)
        self.assertEqual(pages.build(self.root), (expected, 1))
        archive = self.root / "docs/downloads" / ("GuildQueue-" + self.entries[0]["version"] + ".zip")
        archive.write_bytes(b"stale download")
        with self.assertRaisesRegex(ValueError, "out of date"):
            pages.build(self.root, check=True)
        self.assertEqual(archive.read_bytes(), b"stale download")
        self.assertEqual(pages.build(self.root), (expected, 1))

    def test_missing_and_mislabeled_archives_stop_generation(self):
        archive = self.root / ("GuildQueue-" + self.entries[0]["version"] + ".zip")
        archive.unlink()
        with self.assertRaisesRegex(ValueError, "Missing release ZIP"):
            pages.build(self.root)
        with ZipFile(archive, "w") as package:
            package.writestr("GuildQueue/GuildQueue.toc", "## Version: 99.0.0\n")
        with self.assertRaisesRegex(ValueError, "version does not match"):
            pages.build(self.root)
        self.assertFalse((self.root / "docs").exists())

    def test_invalid_duplicate_or_missing_catalog_entries_are_rejected(self):
        original = json.loads(json.dumps(self.entries))
        for version in ("../0.19.0", "01.19.0", "0.19.0-beta"):
            with self.subTest(version=version):
                entries = json.loads(json.dumps(original))
                entries[0]["version"] = version
                self.manifest(entries)
                with self.assertRaisesRegex(ValueError, "canonical"):
                    pages.load_releases(self.root)
        self.manifest(original + [original[0]])
        with self.assertRaisesRegex(ValueError, "unique"):
            pages.load_releases(self.root)
        self.manifest(original[1:])
        with self.assertRaisesRegex(ValueError, "versions must match"):
            pages.load_releases(self.root)
        original[0]["status"] = "unknown"
        self.manifest(original)
        with self.assertRaisesRegex(ValueError, "status"):
            pages.load_releases(self.root)

    def test_changelog_format_and_html_escaping(self):
        text = "## Closed beta change history\n### v1.0.0\n- **First** change.\n  Continued.\n- Use `code`.\n\n## Other\nIgnored."
        self.assertEqual(pages.read_changelog(text), {"1.0.0": ["**First** change. Continued.", "Use `code`."]})
        self.assertEqual(pages.inline_markdown('**Bold** & `<script>`'),
                         '<strong>Bold</strong> &amp; <code>&lt;script&gt;</code>')
        for invalid in ("", "## Closed beta change history\n### v1.0.0\n", text.replace("- **First**", "**First**")):
            with self.assertRaises(ValueError):
                pages.read_changelog(invalid)


if __name__ == "__main__":
    unittest.main()
