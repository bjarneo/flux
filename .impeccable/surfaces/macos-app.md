---
version: 1
slug: "macos-app"
primary_target: "macos/App"
related_targets: ["macos/Sources/FluxKit"]
---

# Surface brief: Flux for macOS

Scope: the main window, the menu bar extra, and the Settings window, Operate mode. The pairing view, the pair request sheet, and the Touch ID approval window stay as they are. The feature windows for agents, browse, camera, remote desktop, and touchpad keep their layout. They follow the light or dark mode of the theme.

Audience and job: an Omarchy user at a Mac next to the Omarchy computer, or away from it on Tailscale. The user must act on what waits: a blocked herdr agent, a sudo approval, or a pair request. The user also moves clipboard text and files, and controls the computer.

Task and content: the Inbox shows real state from every paired computer: agents that need input or finished, approvals, pair requests, transfers, the last clipboard, and what plays now. Send and Control hold the tools for the computer in scope. Computers holds this Mac, the paired computers, and the computers to pair. The Settings window holds the theme and the feature settings. The menu bar extra shows the count of items that need the user, and its panel holds the master item with its one-tap choices.

Constraints: macOS 14 structure. A `NavigationSplitView` with a sidebar of 4 destinations: Inbox with a count badge, Send, Control, and Computers. A `NavigationStack` in the detail column. The scope menu sits in the window toolbar. A "Go" command menu gives Command-1 to Command-4 for the destinations and Command-] for "Show the next item". Every action is a `Button`, so Tab and Space reach it with full keyboard access. The master column and the stack column are focus sections. VoiceOver gets a label, a value, and custom actions on the master tile. Pointer targets are 28 pt high or more. Choice rows and stack tiles are 36 pt high or more. The menu bar extra uses the window style, so its panel reads the agent output when it opens. WCAG 2.2 AA in every theme. STE copy. macOS 14.

Memorable moment: the master tile, framed in the user's own Hyprland active border, holds the agent's question with its choices next to the stack. The menu bar panel holds the same question, so the user answers it without the main window.

Open decisions: none left for the builder. Ask before adding product claims.

## Direction contract

THESIS: Flux is a Hyprland master layout of what needs you. The most urgent item takes the master tile with its whole action, and the rest wait in the stack. It refuses the category default: a device list, then a grid of feature cards for each device.

OWN-WORLD: The user's live Omarchy theme from colors.toml, Tokyo Night as fallback, mapped through a contrast guard. Tiles sit on the background with Hyprland gaps. Only the master carries the user's hyprland_active_border gradient. SF Mono sets window titles, prompts, keys, and data. SF Pro sets body. Red means "needs you", an error, or a destructive action, nothing else.

STORY: The user opens Flux, sees the 1 thing that waits, acts on it in the master tile with 1 tap, and the next item moves up. Send and Control hold the tools for the computer in scope.

FIRST VIEWPORT: Left: the sidebar with Inbox (with a count badge), Send, Control, and Computers. Toolbar: the scope menu "All computers" with a link dot and a battery dot for each computer. Detail, left: the master tile at 60% of the width and full height, with the agent's prompt, its numbered choices directly under the prompt, and Reply. Detail, right: the status line, then the stack in 1 column: approval, now playing, clipboard, and transfer. Menu bar: the Flux mark with the count. Its panel shows the master item with its one-tap choices, then the next items. Signature interaction: Later, Command-], or a click on a stack tile moves that tile into the master position in 200 ms.

FORM: Master and stack, position 2 of 7 on the ordered list, seed key 12a6b1c4.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
