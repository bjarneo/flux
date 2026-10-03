"""Package only the executable and public test instructions; never local state."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

root = Path(__file__).resolve().parent
repository = root.parent
exe = root / "artifacts/win-x64/Flux.Windows.exe"
destination = root / "artifacts/flux-windows-pairing-prototype-v16.zip"
source = root / "artifacts/flux-windows-source-v16.zip"
assert exe.is_file(), "Publish the win-x64 app first"
with ZipFile(destination, "w", ZIP_DEFLATED, compresslevel=6) as bundle:
    bundle.write(exe, "Flux.Windows.exe")
    bundle.write(root / "README.md", "README.md")
    bundle.write(root / "BUILD_STATUS.md", "BUILD_STATUS.md")
with ZipFile(destination) as bundle:
    assert bundle.testzip() is None, "Corrupt test package"
print(destination)

allowed = {".cs", ".csproj", ".xaml", ".props", ".json", ".md", ".py"}
sources = sorted(path for path in root.rglob("*") if path.is_file()
                 and path.suffix in allowed
                 and not any(part in {"bin", "obj", "artifacts"} for part in path.relative_to(root).parts))
with ZipFile(source, "w", ZIP_DEFLATED, compresslevel=6) as bundle:
    for path in sources:
        bundle.write(path, path.relative_to(repository))
    for path in [repository / ".github/workflows/windows.yml",
                 repository / "docs/README.md",
                 repository / "docs/WINDOWS_PARITY.md",
                 repository / "docs/WINDOWS_UI_STANDARDIZATION.md"]:
        bundle.write(path, path.relative_to(repository))
with ZipFile(source) as bundle:
    assert bundle.testzip() is None, "Corrupt source package"
    assert all("/bin/" not in name and "/obj/" not in name and "/artifacts/" not in name
               for name in bundle.namelist()), "Build outputs in source package"
print(source)
