import hashlib
import io
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/prepare-aur.py"


class PrepareAurTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.archive = self.directory / "source.tar.gz"
        self.output = self.directory / "package"

    def archive_source(self, extra=None):
        files = {
            "flux-source-0.2.0/dist/arch/PKGBUILD": (
                ROOT / "dist/arch/PKGBUILD"
            ).read_bytes() + b"\n# Recipe from the release archive.\n",
            "flux-source-0.2.0/dist/arch/omarchy-flux.install": b"# Release install hook.\n",
        }
        files.update(extra or {})
        with tarfile.open(self.archive, "w:gz") as archive:
            for name, content in files.items():
                entry = tarfile.TarInfo(name)
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))

    def run_script(self, tag="v0.2.0", repo="example/flux-source"):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--tag", tag, "--repo", repo,
             "--archive", str(self.archive), "--output", str(self.output)],
            capture_output=True, text=True,
        )

    def test_release_recipe_builds_without_checkout(self):
        self.archive_source()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        recipe = self.output / "PKGBUILD"
        self.assertIn("# Recipe from the release archive.", recipe.read_text())
        self.assertEqual((self.output / "omarchy-flux.install").read_text(), "# Release install hook.\n")
        self.assertEqual((self.output / "omarchy-flux-0.2.0.tar.gz").read_bytes(), self.archive.read_bytes())
        source_dir = self.directory / "src/flux-source-0.2.0"
        source_dir.mkdir(parents=True)
        result = subprocess.run(
            ["bash", "-euc", 'source "$1"; srcdir="$2"; _src; '
             'printf "%s\\n" "$pkgver" "$PWD" "${source[0]}" "${sha256sums[0]}"; '
             '! declare -F pkgver', "bash", str(recipe), str(source_dir.parent)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "0.2.0", str(source_dir),
            "omarchy-flux-0.2.0.tar.gz::https://github.com/example/flux-source/archive/refs/tags/v0.2.0.tar.gz",
            hashlib.sha256(self.archive.read_bytes()).hexdigest(),
        ])

    def test_rejects_prerelease_and_shell_input(self):
        for tag, repo in [("v0.2.0-rc1", "example/flux"), ("v0.2.0;id", "example/flux"),
                          ("v0.2.0", "example/flux'$(id)")]:
            with self.subTest(tag=tag, repo=repo):
                self.assertNotEqual(self.run_script(tag, repo).returncode, 0)
                self.assertFalse(self.output.exists())

    def test_rejects_multiple_archive_roots(self):
        self.archive_source({"other/file": b"unexpected"})
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("one root directory", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
