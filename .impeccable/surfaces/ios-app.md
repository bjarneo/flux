---
version: 1
slug: "ios-app"
primary_target: "ios/App"
related_targets: ["macos/Sources/FluxKit"]
---

# Surface brief: Flux for iOS

Scope: the whole iPhone app structure, Operate mode. The pairing sheet and the Face ID approval sheet stay as they are. Only their tint and their light or dark mode follow the theme.

Audience and job: an Omarchy user with the iPhone in one hand, often away from the desk. The user must act on what waits: a blocked herdr agent, a sudo approval, or a pair request. The user also moves clipboard text, photos, and files.

Task and content: the Inbox shows real state from every paired computer: agents that need input or finished, approvals, pair requests, transfers, the last clipboard, and what plays now. Send and Control hold the tools for the computer in scope. Computers holds pairing, the theme, the settings, and Flux on or off.

Constraints: HIG structure. A `TabView` with 4 tabs: Inbox with a badge, Send, Control, and Computers. A `NavigationStack` in each tab, with the system back button and the edge swipe. The scope chip sits in the navigation bar of each tab root. Lay out inside the safe areas. Every control takes taps on 44 by 44 pt or more. Choice rows and stack tiles are 48 pt high or more. VoiceOver gets a label, a value, and a hint for each control, and custom actions on the master tile. Text uses system text styles, so Dynamic Type works from xSmall to the accessibility sizes. Reduce Motion turns off each transition. WCAG 2.2 AA in every theme. STE copy. iOS 17. A window of 600 pt or more uses the master and stack split, so iPad and iPhone landscape get the split.

Memorable moment: the master tile, framed in the user's own Hyprland active border, holds the agent's question with its choices at thumb height.

Open decisions: none left for the builder. Ask before adding product claims.

## Direction contract

THESIS: Flux is a Hyprland master layout of what needs you. The most urgent item takes the master tile with its whole action, and the rest wait in the stack. It refuses the category default: a device list, then a grid of feature cards for each device.

OWN-WORLD: The user's live Omarchy theme from colors.toml, Tokyo Night as fallback, mapped through a contrast guard. Tiles sit on the background with Hyprland gaps. Only the master carries the user's hyprland_active_border gradient. SF Mono sets window titles, prompts, keys, and data. SF Pro sets body. Red means "needs you", an error, or a destructive action, nothing else.

STORY: The user opens Flux, sees the 1 thing that waits, acts on it in the master tile with 1 tap, and the next item moves up. Send and Control hold the tools for the computer in scope.

FIRST VIEWPORT: Top: the navigation bar holds the scope chip "All computers" with a link dot and a battery dot for each computer. Under it, the status line. Master tile at about 55% of the height: the agent's prompt, its numbered choices, and Reply at thumb height. Below: a 2 by 2 stack of approval, now playing, clipboard, and transfer. Bottom: the tab bar with Inbox (with a badge), Send, Control, and Computers. In a window of 600 pt or more, the master takes 60% of the width at full height, its choices sit directly under the prompt, and the status line and the stack fill a column on the right. Signature interaction: a swipe on the master, or a tap on a stack tile, moves that tile into the master position in 200 ms.

FORM: Master and stack, position 2 of 7 on the ordered list, seed key 12a6b1c4.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
