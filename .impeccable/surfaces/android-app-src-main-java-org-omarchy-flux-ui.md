---
version: 1
slug: "android-app-src-main-java-org-omarchy-flux-ui"
primary_target: "android/app/src/main/java/org/omarchy/flux/ui"
related_targets: []
---

# Surface brief: Flux for Android

Scope: the whole Android app structure, Operate mode. The pairing sheet and the fingerprint approval screen stay as they are.

Audience and job: an Omarchy user with the phone in one hand, often away from the desk, who must act on what waits (a blocked herdr agent, a sudo approval, a pair request) and move clipboard text and files.

Task and content: the Inbox shows real state from every paired computer: agents that need input or finished, approvals, pair requests, transfers, the last clipboard, and what plays now. Send and Control hold the tools for the computer in scope. Computers holds pairing, sync switches, theme, and Flux on or off.

Constraints: Material 3 structure (navigation bar with 4 destinations, system Back with predictive back, insets, 48 dp targets, TalkBack roles), WCAG AA in every theme, 200% font scale, STE copy, min SDK 29.

Memorable moment: the master tile, framed in the user's own Hyprland active border, holds the agent's question with its choices at thumb height.

Open decisions: none left for the builder; ask before adding product claims.

## Direction contract

THESIS: Flux is a Hyprland master layout of what needs you. The most urgent item takes the master tile with its whole action, and the rest wait in the stack. It refuses the category default: a device list, then a grid of feature cards for each device.

OWN-WORLD: The user's live Omarchy theme from colors.toml, Tokyo Night as fallback, mapped through a contrast guard. Tiles sit on the background with Hyprland gaps. Only the master carries the user's hyprland_active_border gradient. Mono sets window titles, prompts, keys, and data; Roboto sets body. Red means "needs you" or an error, nothing else.

STORY: The user opens Flux, sees the 1 thing that waits, acts on it in the master tile with 1 tap, and the next item moves up. Send and Control hold the tools for the computer in scope.

FIRST VIEWPORT: Top: a scope chip "All computers" with a link and battery dot for each computer. Master tile at about 55% of the height: the agent's prompt, its numbered choices, and Reply at thumb height. Below: a 2 by 2 stack of approval, now playing, clipboard, and transfer. Bottom: the navigation bar Inbox (with a count), Send, Control, Computers. Signature interaction: a swipe on the master, or a tap on a stack tile, moves that tile into the master position in 200 ms.

FORM: Master and stack, position 2 of 7 on the ordered list, seed key 12a6b1c4.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
