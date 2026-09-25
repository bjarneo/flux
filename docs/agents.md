# Agent skill

[Documentation index](README.md)

The repository includes a complete Flux skill in [`skills/omarchy-flux/`](../skills/omarchy-flux/SKILL.md).
It covers desktop and Android setup, CLI operations, diagnostics, development, AUR packages, and APK releases.
The root [`AGENTS.md`](../AGENTS.md) points repository agents to the skill and documentation.

## Use the skill from the checkout

Ask your agent to read `skills/omarchy-flux/SKILL.md` before a Flux task.
The skill loads its runtime or build reference as needed.

Example requests:

- `Use the Flux skill to diagnose why my paired phone is offline.`
- `Use the Flux skill to install the Qt app, CLI, daemon, and shell plugin from this checkout.`
- `Use the Flux skill to send report.txt to my Pixel 8 and verify the transfer.`
- `Use the Flux skill to prepare a signed APK and AUR release for v0.2.0.`

## Install for an agent

For agents that discover skills in `~/.agents/skills`, run from the repository root:

```sh
mkdir -p "$HOME/.agents/skills"
ln -s "$PWD/skills/omarchy-flux" "$HOME/.agents/skills/omarchy-flux"
```

For another agent, place the complete `omarchy-flux` directory in that agent's documented skill directory.
Keep `references/` beside `SKILL.md`.
If an entry already exists, inspect it before you replace it.

The skill does not require an MCP server.
It uses the local CLI, repository tools, and GitHub CLI where needed.
An installed skill asks for the checkout path when a task needs source files.

## Scope and checks

The skill covers:

- Explicit device selection and JSON state.
- Pairing with a user-confirmed key comparison.
- File, clipboard, notification, SMS, media, and stream operations.
- User-service and network diagnosis.
- Qt and shell host compatibility.
- Approval trust boundaries and password fallback.
- Local builds and component checks.
- Release secrets, tag selection, AUR metadata, APK keys, and version codes.

The skill reports tests and required user actions separately from completed work.
It does not equate a local build with a published release.

Sample skill checks live in [`evals/evals.json`](../skills/omarchy-flux/evals/evals.json).
They cover device selection, local installation, and release preparation.
