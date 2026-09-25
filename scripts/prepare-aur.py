#!/usr/bin/env python3
"""Create a self-contained AUR recipe from a stable GitHub release archive."""

import argparse
import hashlib
import io
import re
import tarfile
import urllib.request
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="Stable tag such as v0.1.0")
    parser.add_argument("--repo", required=True, help="GitHub OWNER/REPOSITORY")
    parser.add_argument("--output", type=Path, default=Path("dist/aur"))
    parser.add_argument("--archive", type=Path, help="Use a local copy of the GitHub tag archive")
    args = parser.parse_args()
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.tag):
        parser.error("Use a stable tag such as v0.1.0.")
    if not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", args.repo):
        parser.error("Use a GitHub repository in OWNER/REPOSITORY form.")

    version = args.tag[1:]
    url = f"https://github.com/{args.repo}"
    source_url = f"{url}/archive/refs/tags/{args.tag}.tar.gz"
    if args.archive:
        archive = args.archive.read_bytes()
    else:
        with urllib.request.urlopen(source_url, timeout=120) as response:
            archive = response.read()

    # Read the recipe from the archive so it matches the released source.
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as source:
        roots = {member.name.split("/")[0] for member in source.getmembers()}
        if len(roots) != 1:
            parser.error("The source archive must have one root directory.")
        root = roots.pop()
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", root) or root in (".", ".."):
            parser.error("The source archive has an invalid root directory.")

        def read_member(path):
            member = source.getmember(f"{root}/{path}")
            if not member.isfile():
                parser.error(f"The archive member is not a regular file: {path}")
            return source.extractfile(member).read()

        recipe = read_member("dist/arch/PKGBUILD").decode()
        install = read_member("dist/arch/omarchy-flux.install")

    values = {
        "pkgver": version,
        "url": url,
        "_source_url": source_url,
        "_source_sha256": hashlib.sha256(archive).hexdigest(),
        "_source_dir": root,
    }
    for key, value in values.items():
        recipe, count = re.subn(rf"^{key}=.*$", f"{key}='{value}'", recipe, flags=re.MULTILINE)
        if count != 1:
            parser.error(f"Expected one {key} assignment in the release PKGBUILD.")

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "PKGBUILD").write_text(recipe)
    (args.output / "omarchy-flux.install").write_bytes(install)
    (args.output / f"omarchy-flux-{version}.tar.gz").write_bytes(archive)
    print(f"Created the AUR recipe in {args.output}")


if __name__ == "__main__":
    main()
