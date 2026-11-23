"""Build the dependency-free downloads site; README.md is the changelog source.

Add a versioned ZIP and README changelog, update site/releases.json, then run:
    python3 site/build.py
    python3 site/build.py --check
GitHub Pages publishes the generated docs/ files from main. Never hand-edit them.
"""

import argparse
import html
import json
from pathlib import Path
import re
from string import Template
import sys
from zipfile import BadZipFile, ZipFile


ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\Z")


def read_changelog(readme):
    marker = "## Closed beta change history\n"
    if marker not in readme:
        raise ValueError("README.md is missing its closed beta changelog.")
    section = readme.split(marker, 1)[1].split("\n## ", 1)[0]
    releases, current = {}, None
    for line in section.splitlines():
        if line.startswith("### "):
            match = re.fullmatch(r"### v([0-9]+\.[0-9]+\.[0-9]+)(?: — .+)?", line)
            if not match or not VERSION.fullmatch(match[1]) or match[1] in releases:
                raise ValueError("Use unique canonical vX.Y.Z changelog headings.")
            current = releases[match[1]] = []
        elif line.startswith("- ") and current is not None:
            current.append(line[2:].strip())
        elif line.startswith("  ") and current:
            current[-1] += " " + line.strip()
        elif line.strip():
            raise ValueError("Release changes must be bulleted under a version heading.")
    if not releases or any(not notes or any(not note for note in notes) for notes in releases.values()):
        raise ValueError("Every release needs at least one nonempty changelog bullet.")
    return releases


def inline_markdown(text):
    """Support just the bold/code notation used by the release notes, escaping HTML."""
    escaped = html.escape(text)
    return re.sub(r"\*\*(.+?)\*\*|`([^`]+)`", lambda match:
                  "<strong>" + match[1] + "</strong>" if match[1] is not None
                  else "<code>" + match[2] + "</code>", escaped)


def load_releases(root):
    entries = json.loads((root / "site/releases.json").read_text(encoding="utf-8"))
    notes = read_changelog((root / "README.md").read_text(encoding="utf-8"))
    if not isinstance(entries, list) or not entries:
        raise ValueError("site/releases.json must contain a nonempty release list.")
    releases, seen = [], set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"version", "status"}:
            raise ValueError("Each release needs only version and status fields.")
        version, status = entry["version"], entry["status"]
        if not isinstance(version, str) or not VERSION.fullmatch(version) or version in seen:
            raise ValueError("Release versions must be unique canonical X.Y.Z values.")
        if status not in ("released", "preview"):
            raise ValueError("Release status must be released or preview.")
        if version not in notes:
            raise ValueError("Missing README changelog for v" + version)
        seen.add(version)
        filename = "GuildQueue-" + version + ".zip"
        archive = root / filename
        if not archive.is_file():
            raise ValueError("Missing release ZIP: " + filename)
        with ZipFile(archive) as package:
            if package.testzip() is not None:
                raise ValueError("Release ZIP failed its integrity check: " + filename)
            toc = package.read("GuildQueue/GuildQueue.toc").decode("utf-8-sig")
            match = re.search(r"^## Version:\s*([^\r\n]+)", toc, re.MULTILINE)
            if not match or match[1].strip() != version:
                raise ValueError("Release ZIP version does not match " + filename)
        payload = archive.read_bytes()
        releases.append({"version": version, "status": status, "notes": notes[version],
                         "filename": filename, "download": "downloads/" + filename,
                         "payload": payload, "size": f"{len(payload) / 1024:.1f} KB"})
    if seen != set(notes):
        raise ValueError("Changelog and site/releases.json versions must match.")
    if not any(release["status"] == "released" for release in releases):
        raise ValueError("At least one released version is required.")
    return sorted(releases, key=lambda item: tuple(map(int, item["version"].split("."))), reverse=True)


def release_card(release):
    version = release["version"]
    preview = release["status"] == "preview"
    badge = "Upcoming · Preview build" if preview else "Closed-beta release"
    button_class = "button secondary" if preview else "button"
    warning = ('      <p class="preview-note">Not yet released. In-game visual and multiplayer verification is still needed.</p>\n'
               if preview else "")
    changes = "\n".join("        <li>" + inline_markdown(note) + "</li>" for note in release["notes"])
    return f'''    <article class="release" id="v{version.replace('.', '-')}" data-version="{version}">
      <div class="release-head">
        <div>
          <span class="badge{' preview' if preview else ''}">{badge}</span>
          <h3>v{version}</h3>
          <p class="release-meta quiet">{release['size']} · ZIP · WoW:Forever</p>
        </div>
        <a class="{button_class}" href="{release['download']}" download="{release['filename']}" aria-label="Download Guild Queue v{version} ZIP">Download ZIP</a>
      </div>
{warning}      <ul class="changes">
{changes}
      </ul>
    </article>'''


def generated_files(root):
    releases = load_releases(root)
    primary = next(release for release in releases if release["status"] == "released")
    template = Template((root / "site/template.html").read_text(encoding="utf-8"))
    page = template.substitute(primary_download=primary["download"], primary_version=primary["version"],
                               release_cards="\n".join(map(release_card, releases)))
    outputs = {root / "docs/index.html": page.encode("utf-8"), root / "docs/.nojekyll": b""}
    for release in releases:
        outputs[root / "docs" / release["download"]] = release["payload"]
    return outputs


def build(root=ROOT, check=False):
    outputs = generated_files(root)
    changed = [path for path, payload in outputs.items() if not path.is_file() or path.read_bytes() != payload]
    if check and changed:
        raise ValueError("Site is out of date; run python3 site/build.py. Files: "
                         + ", ".join(str(path.relative_to(root)) for path in changed))
    if not check:
        for path in changed:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(outputs[path])
    return len(outputs), len(changed)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="Check generated HTML and ZIPs without changing files")
    args = parser.parse_args()
    try:
        count, changed = build(check=args.check)
    except (ValueError, OSError, BadZipFile, KeyError) as error:
        print("Downloads site: " + str(error), file=sys.stderr)
        return 1
    print(f"Downloads site: {count} files checked, {changed} {'outdated' if args.check else 'updated'}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
