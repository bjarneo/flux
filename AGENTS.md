# Flux agent guide

Read [the Flux skill](skills/omarchy-flux/SKILL.md) for Flux use, installation, diagnostics, development, and releases.
Start with [the documentation index](docs/README.md) for detailed topics.

- Inspect `git status --short` before source changes.
- Keep shared Qt views in `gui/qml/` compatible with both desktop hosts.
- Keep device state and network operations in `fluxd`.
- Read [the approval design](docs/approve.md) before approval changes.
- Use [the development checks](docs/development.md) for the changed component.
- Use [the release guide](docs/releasing.md) for package and workflow changes.
- Keep secrets and local SDK paths out of the repository.
- Preserve the source owner's license choice. The repository currently has no selected license.
