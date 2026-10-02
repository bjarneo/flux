---
name: Flux for Android
description: The phone side of Flux. A Hyprland master layout of what needs the user, in the live Omarchy theme of the computer.
colors:
  bg: "#16161E"
  off-tile: "#1A1B26"
  tile: "#1F2335"
  tile-hi: "#24283B"
  line: "#292E42"
  line-hi: "#3B4261"
  accent-tile: "#1E2845"
  text: "#C0CAF5"
  sub: "#8B94BE"
  dim: "#66709B"
  on-accent: "#16161E"
  accent: "#7AA2F7"
  cyan: "#7DCFFF"
  green: "#9ECE6A"
  magenta: "#BB9AF7"
  orange: "#FF9E64"
  red: "#F7768E"
  yellow: "#E0AF68"
typography:
  master-title:
    fontFamily: "Roboto, sans-serif"
    fontSize: "20sp"
    fontWeight: 600
  empty-title:
    fontFamily: "Roboto, sans-serif"
    fontSize: "22sp"
    fontWeight: 600
  top-bar-title:
    fontFamily: "Roboto, sans-serif"
    fontSize: "18sp"
    fontWeight: 600
    lineHeight: 1.2
  tool-label:
    fontFamily: "Roboto, sans-serif"
    fontSize: "15sp"
    fontWeight: 600
  section-label:
    fontFamily: "Roboto, sans-serif"
    fontSize: "14sp"
    fontWeight: 500
    lineHeight: "20sp"
  body:
    fontFamily: "Roboto, sans-serif"
    fontSize: "14sp"
    fontWeight: 400
    lineHeight: 1.35
  button:
    fontFamily: "Roboto, sans-serif"
    fontSize: "14sp"
    fontWeight: 600
  secondary:
    fontFamily: "Roboto, sans-serif"
    fontSize: "13sp"
    fontWeight: 400
    lineHeight: 1.3
  tile-label:
    fontFamily: "Roboto, sans-serif"
    fontSize: "12sp"
    fontWeight: 500
    lineHeight: 1.35
  prompt:
    fontFamily: "monospace"
    fontSize: "14sp"
    fontWeight: 400
    lineHeight: 1.35
  window-title:
    fontFamily: "monospace"
    fontSize: "13sp"
    fontWeight: 400
    lineHeight: 1.35
  choice-key:
    fontFamily: "monospace"
    fontSize: "15sp"
    fontWeight: 700
  data:
    fontFamily: "monospace"
    fontSize: "12sp"
    fontWeight: 400
rounded:
  skeleton: "3px"
  choice: "8px"
  chip: "10px"
  tile: "12px"
  sheet: "20px"
  round: "9999px"
spacing:
  gap: "8px"
  gutter: "10px"
  tile-inset: "14px"
  master-inset: "16px"
  master-tool-inset: "18px"
  empty-inset: "20px"
  target: "48px"
components:
  button-filled:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    typography: "{typography.button}"
    rounded: "{rounded.tile}"
    padding: "10px 18px"
    height: "48px"
  button-tonal:
    backgroundColor: "{colors.line}"
    textColor: "{colors.text}"
    typography: "{typography.button}"
    rounded: "{rounded.tile}"
    padding: "10px 18px"
    height: "48px"
  button-outlined:
    textColor: "{colors.accent}"
    typography: "{typography.button}"
    rounded: "{rounded.tile}"
    padding: "10px 18px"
    height: "48px"
  button-destructive:
    textColor: "{colors.red}"
    typography: "{typography.button}"
    rounded: "{rounded.tile}"
    padding: "10px 18px"
    height: "48px"
  button-text:
    textColor: "{colors.accent}"
    typography: "{typography.button}"
    rounded: "{rounded.tile}"
    padding: "10px 12px"
    height: "48px"
  tile:
    backgroundColor: "{colors.tile}"
    textColor: "{colors.text}"
    rounded: "{rounded.tile}"
    padding: "{spacing.tile-inset}"
  master-tile:
    backgroundColor: "{colors.tile}"
    textColor: "{colors.text}"
    rounded: "{rounded.tile}"
    padding: "{spacing.master-inset}"
  stack-tile:
    backgroundColor: "{colors.tile}"
    textColor: "{colors.text}"
    rounded: "{rounded.tile}"
    padding: "10px 12px"
    height: "48px"
  choice-row:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.choice}"
    padding: "10px 12px"
    height: "48px"
  choice-row-selected:
    backgroundColor: "{colors.accent-tile}"
    textColor: "{colors.text}"
    rounded: "{rounded.choice}"
    padding: "10px 12px"
    height: "48px"
  master-tool:
    backgroundColor: "{colors.tile-hi}"
    textColor: "{colors.text}"
    rounded: "{rounded.tile}"
    padding: "{spacing.master-tool-inset}"
    height: "128px"
  tool-row:
    backgroundColor: "{colors.tile}"
    textColor: "{colors.text}"
    typography: "{typography.tool-label}"
    rounded: "{rounded.tile}"
    padding: "10px 14px"
    height: "56px"
  scope-chip:
    backgroundColor: "{colors.tile}"
    textColor: "{colors.text}"
    rounded: "{rounded.chip}"
    padding: "0 6px 0 12px"
    height: "48px"
  choice-chip:
    backgroundColor: "{colors.tile}"
    textColor: "{colors.sub}"
    rounded: "{rounded.choice}"
    padding: "6px 12px"
    height: "40px"
  choice-chip-selected:
    backgroundColor: "{colors.accent-tile}"
    textColor: "{colors.text}"
    rounded: "{rounded.choice}"
    padding: "6px 12px"
    height: "40px"
  field-key:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.tile}"
    size: "56px"
  needs-badge:
    backgroundColor: "{colors.red}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.choice}"
    padding: "1px 7px"
  command-block:
    backgroundColor: "{colors.off-tile}"
    textColor: "{colors.text}"
    rounded: "{rounded.choice}"
    padding: "2px 2px 2px 12px"
---

# Design System: Flux for Android

## Overview

**Creative North Star: "The Master Layout of What Needs You"**

Flux for Android looks like the user's own Omarchy desktop. Tiles sit on the page with Hyprland gaps. The item that needs the user most takes the master tile, and the other items wait in the stack. Only the master tile carries the active border gradient of the computer, as the focused window does in Hyprland.

The app has no palette of its own. The colors come from the live Omarchy theme of the computer in scope, through a contrast guard. Tokyo Night is the fallback when no computer sent a theme. The token values in this file are the Tokyo Night reference set. The roles are the system, and the values change with the theme.

The density is that of a tiled desktop: 8 dp gaps, 12 dp corners, flat tiles, and no shadows. Mono sets what the computer says, such as window titles, prompts, keys, and data. Roboto sets what Flux says. The app rejects the category default of a device list, then a grid of feature cards for each device.

**Key Characteristics:**

- The colors are roles from the theme of the computer, not fixed values.
- Every role pair reaches WCAG 2.2 AA in every theme: 4.5:1 for text, and 3:1 for icons and borders.
- 1 master tile with the `hyprland_active_border` gradient, and a stack of plain tiles.
- Red means only "needs you" and errors.
- Mono for computer data, Roboto for Flux text.
- Flat tiles with 1 dp borders. Depth comes from tonal steps.
- 1 motion duration: 200 ms with the standard easing, and no motion when Remove animations is on.

## Colors

The palette is a set of roles that the contrast guard fills from the Omarchy theme of the computer in scope.

### Theme source and the contrast guard

`fluxd` sends the theme in a `flux.theme` packet. See `docs/omarchy.md`, section "Theme packet". `paletteOf` in `android/app/src/main/java/org/omarchy/flux/theme/ThemePalette.kt` turns the packet into a `PaletteSpec`. `TiledTheme` in `TiledKit.kt` turns the spec into the `Tn` tokens and the Material 3 color scheme.

- The guard moves only the lightness of a color. The hue of the theme stays.
- `text` and `sub` reach 4.5:1 on `bg`, `off-tile`, `tile`, `tile-hi`, `line`, and `accent-tile`.
- The fills `accent`, `cyan`, `green`, `magenta`, `orange`, `red`, and `yellow` reach 4.5:1 as text on the surfaces and on `accent-tile`. On `line`, they reach 3:1. Use them on `line` for icons and borders only.
- `on-accent` reaches 4.5:1 on each fill.
- `dim` reaches 3:1 on `bg`, `tile`, and `tile-hi`.
- Each border gradient color reaches 3:1 on `bg` and `tile`.
- When the theme accent looks like red, the blue, cyan, or magenta of the theme takes its place. The border gradient keeps the theme accent.
- The theme setting has 4 choices: Computer, System, Light, and Dark. Computer is the default. Without a computer theme, the app uses Tokyo Night in the dark mode and Tokyo Night Day in the light mode.

### Primary

- **Theme Accent**, `accent`: The primary color for actions and selection. It fills the main button and the Send key, and it colors the choice digits, tool icons, outlined and text buttons, and focused fields. On Tokyo Night it is blue.
- **Accent Tile**, `accent-tile`: A tile with the hue of the accent and the luminance of `tile-hi`. It fills a selected choice. The guard derives it from `tile-hi` with 18% of the accent.

### Semantic colors

- **Needs-You Red**, `red`: An item that needs the user, the count badge, errors, and the Destructive button kind. See the One Red Rule.
- **Done Green**, `green`: A connected link dot, an agent that is done, a finished transfer, a player that plays, and a battery that charges.
- **Clipboard Cyan**, `cyan`: The clipboard item, a battery above 50%, and the second stop of the fallback border gradient.
- **Warning Yellow**, `yellow`: A battery at 50% or less, the offline Inbox icon, and the top edge of the pairing sheet.
- **Low Orange**, `orange`: A battery at 20% or less.
- **Theme Magenta**, `magenta`: The tertiary role of the Material scheme. It has no Flux meaning of its own.
- **Terminal Blue**, `termBlue`: The blue of the theme for ANSI blue in agent output. It can differ from the accent. It has no frontmatter token because Tokyo Night uses the accent value.

### Neutral

- **Page**, `bg`: The page, the sheet surface, and the fill of an unselected choice row in the master.
- **Off Tile**, `off-tile`: A tile that is off, the agent output, and the command block.
- **Tile**, `tile`: The default tile, the stack tile, the scope chip, and the square buttons.
- **Raised Tile**, `tile-hi`: The master tool of a destination, menus, and dialogs.
- **Line**, `line`: The 1 dp border of a tile, and the tonal button fill.
- **Raised Line**, `line-hi`: The border of the master tool.
- **Body Ink**, `text`: Body text, titles, and labels that carry the main value.
- **Second Ink**, `sub`: Hints, labels, placeholders, secondary data, and icons of a tool that is off.
- **Dim**, `dim`: Borders, the outlined button border, the drag handle, and disabled icons. It is never text.
- **On Accent**, `on-accent`: Text and icons on a fill of the accent or of a semantic color.

### Light reference: Tokyo Night Day

The light fallback uses the same roles. Its tiles are darker steps of the page. Its body ink is a neutral slate, so that blue means "you can tap this".

- Surfaces: `bg` `#E1E2E7`, `off-tile` `#DDDEE4`, `tile` `#D9DBE1`, `tile-hi` `#D4D5DC`, `line` `#C4C8DA`, `line-hi` `#A8AECB`.
- Inks: `text` `#343B58`, `sub` `#44518A`, `dim` `#70769E`, `on-accent` `#FFFFFF`.
- Fills: `accent` `#2457B8`, `cyan` `#006486`, `green` `#496529`, `magenta` `#7B31CF`, `orange` `#914A00`, `red` `#BA0046`, `yellow` `#765729`.

### Named Rules

**The Theme Owns the Values Rule.** Use a `Tn` role, never a fixed color. A new color pair must pass the guard in Tokyo Night, Tokyo Night Day, and a sample theme from `core/DebugTheme.kt`.

**The One Red Rule.** Red means "needs you" or an error. The Destructive button kind is the 1 other use. A low battery is orange or yellow, never red.

**The One Selection Color Rule.** A selected item takes `accent-tile` and a 2 dp accent border. No other color marks a selection.

## Typography

**Body Font:** Roboto, the Android default sans-serif.
**Label/Mono Font:** The Android monospace family, `FontFamily.Monospace`.

**Character:** Roboto speaks for Flux in plain sentences. Mono shows what comes from the computer, so the user sees at once which text is the agent's and which text is the app's.

### Hierarchy

- **Empty title**, 600, 22 sp: The title of the empty Inbox tile and the media title in the master.
- **Master title**, 600, 20 sp: The title of the item in the master tile, and the label of a master tool.
- **Top bar title**, 600, 18 sp, line height 1.2: The title of a feature screen. TalkBack reads it as a heading.
- **Tool label**, 600, 15 sp: The label of a tool row, an action tile, and a computer row.
- **Section label**, Material 3 Title Small, 500, 14 sp: The heading of a group of tiles, in sentence case.
- **Body**, 400, 14 sp, line height 1.35: Descriptions and the choice labels.
- **Button**, 600, 14 sp: Every `FluxButton` label.
- **Secondary**, 400, 13 sp, line height 1.3: The line under a tool label, and error text.
- **Tile label**, 500, 12 sp, line height 1.35: The label of a value or a group in a tile, in `sub`.
- **Prompt**, mono 400, 14 sp, line height 1.35: The question of an agent and a clipboard preview.
- **Window title**, 13 sp in the master and 12 sp in the stack, line height 1.35: The state word in Roboto 500 and the state color, then the source in mono and `sub`.
- **Choice key**, mono 700, 15 sp, in the accent: The digit of an agent choice.
- **Data**, mono 400, 12 sp to 13 sp: The computer name, the top bar context line, the user and TTY of an approval, file names, keys, and badges.

All text grows with the Android font size. Layouts hold at 200%. A key label shrinks to fit its key, to half its size at most. The navigation labels stop at a font scale of 1.5.

### Named Rules

**The Mono Is the Computer Rule.** Set text in mono only when it comes from the computer: window titles, prompts, commands, keys, file names, and data. Set Flux sentences, labels, and headings in Roboto.

**The Sentence Case Rule.** Write labels and headings in sentence case, as written. Do not use all caps or letter spacing for labels.

## Layout

The app follows the Hyprland master layout. The master tile holds the first item with its whole action. The stack holds the other items.

- **Gaps and gutter:** Tiles keep an 8 dp gap. The screen gutter is 10 dp. The shell top bar starts 6 dp further in, to align the Flux mark.
- **Phone in portrait:** The Inbox is 1 grid with 2 columns. The status line comes first, then the master across the full width. The master takes at least 55% of the height under the status line, so that 2 stack rows show above the navigation bar. The choices and Reply sit at the bottom of the master, at thumb height.
- **Wide window, 600 dp and more:** A navigation rail replaces the navigation bar. The Inbox splits: the master takes 60% of the width at full height, and the status line and the stack fill a column on the right. The choices sit directly under the prompt.
- **Short window, under 480 dp high:** The top bar takes less height. Below 460 dp, the master is compact. Its inset is 12 dp, its gaps are 6 dp and 10 dp, the prompt is shorter, and Reply moves to the top row.
- **Content width:** Screens other than the Inbox scroll in `CappedScrollColumn`. The content is at most 840 dp wide and stays in the center. Choice and action rows in the master are at most 600 dp wide.
- **Destinations:** Inbox, Send, Control, and Computers. Send and Control open with 1 master tool, then groups of tool rows under section labels.
- **Rank:** The Inbox order is the order of `InboxKind` in `core/InboxModel.kt`: agent input, approval, pair request, media, clipboard, transfer, agent done, and agent working. What needs the user comes first.
- **Targets:** Every control takes taps on at least 48 by 48 dp.

## Elevation & Depth

The system is flat. Tiles have no shadows. Depth comes from 4 tonal surface steps, `bg`, `off-tile`, `tile`, and `tile-hi`, and from 1 dp borders in `line`. In a dark theme, the tiles are lighter steps of the page. In a light theme, they are darker steps. The only emphasis beyond tone is the 2 dp active border gradient of the master tile.

### Named Rules

**The Flat Tile Rule.** Do not add a shadow to a tile. To raise a tile, step its fill to `tile-hi` and its border to `line-hi`.

**The One Active Window Rule.** Only the tile in the master position carries the active border: the master tile, or the empty Inbox tile in its place. The gradient is the `hyprland_active_border` colors of the theme at its angle. Without a theme border, it goes from the accent to cyan, corner to corner.

## Shapes

The corners follow the Omarchy window: 12 dp on tiles, buttons, fields, and the field key. Smaller parts inside a tile take 8 dp: choice rows, choice chips, square buttons, the command block, and the count badge. The scope chip takes 10 dp. Sheets take 20 dp at the top corners. Status dots, link dots, and round media controls are circles. A computer that is available to pair has a dashed border of 1.5 dp, with 6 dp dashes and 5 dp spaces.

A pressed tile changes its border to the accent. A selected choice changes its border to 2 dp of the accent. A tile or choice that takes no taps shows at 55% alpha.

## Components

### Buttons

`FluxButton` with `ButtonKind` is the 1 button of the app.

- **Shape:** The tile corner, 12 dp. The button is at least 48 dp high, and its label wraps at a large font size.
- **Filled:** The accent fill with `on-accent` text. Use it for the main action of a screen or a tile.
- **Tonal:** The `line` fill with `text`. Use it for a second action that needs weight, such as Stop or Done.
- **Outlined:** A 1 dp `dim` border with accent text. Use it for a second action, such as Reply when the master shows choices. Reply is filled when it is the only action of the master.
- **Destructive:** A 1 dp red border with red text. Use it for an action that ends or deletes something for good.
- **Text:** Accent text with a 12 dp side inset. Use it for a small action in a line of text, such as Retry or Later.
- **States:** A busy button shows a spinner in the place of its icon, keeps its colors, and takes no taps. A disabled filled or tonal button takes the `tile` fill and `dim` text.

### Chips

- **Scope chip:** A `tile` chip with a 10 dp corner and a `line` border, at least 48 dp high. It shows "All computers" or 1 computer, then a link dot and a battery dot for each computer, then an expand icon. A tap opens the scope menu.
- **Choice chip:** A choice of a small group, such as a player or a camera mode. It is at least 40 dp high and takes taps on 48 dp. The label is 13 sp, 600, in `sub`. A selected chip takes `accent-tile`, a 2 dp accent border, and `text`.

### Cards / Containers

- **Corner Style:** 12 dp.
- **Background:** `tile` by default, `tile-hi` for the master tool, and `off-tile` for a tile that is off.
- **Shadow Strategy:** None. See Elevation & Depth.
- **Border:** 1 dp `line`. A stack tile that needs the user has a 1 dp red border.
- **Internal Padding:** 14 dp for a tile, 16 dp for the master tile, 18 dp for the master tool, and 20 dp for the empty Inbox tile.

### Inputs / Fields

- **Style:** The Material 3 outlined field on the tile corner, with 14 sp text in `text`. The placeholder is in `sub`. A field for a command uses mono.
- **Focus:** The border changes from `dim` to the accent.
- **Field key:** The Send or Run key at the end of a field is a 56 dp square on the tile corner. It takes the accent fill while it can send, else the `tile` fill with a `line` border.

### Navigation

- **Bar:** The Material 3 navigation bar in a compact window, with 4 destinations: Inbox, Send, Control, and Computers. The Inbox icon shows a red badge with the number of items that need the user, up to "9+".
- **Rail:** The Material 3 navigation rail in a window of 600 dp and more, with the same destinations.
- **Top bar:** A destination shows the Flux mark and the scope chip. A feature screen shows a 40 dp back button, the title, and an optional mono context line. When the actions leave the title too little width, they move to a second row.
- **Motion:** Destinations fade through in 240 ms. A feature screen moves on the horizontal axis in 220 ms. Predictive back follows the gesture.

### Master tile

The signature component. It holds the first Inbox item with its whole action.

- The top row holds the window title, the computer in mono under it, and Later.
- An agent item shows its title, the prompt in mono, the numbered choices, and Reply. A choice row is at least 48 dp high, on `bg` with a `line` border. The agent's cursor choice takes `accent-tile` and a 2 dp accent border.
- The prompt comes from `agentPrompt` in `core/InboxModel.kt`. It keeps the lines nearest the choices, because they hold the command that a choice approves.
- A swipe to the side, Later, or the TalkBack action "Show the next item" moves the master to the end of the stack. A tap on a stack tile moves that tile to the master. Each move takes 200 ms.

### Stack tile

A `tile` row with the window title, a 14 sp 600 title, and a 12 sp `sub` line, each on 1 line. From a font scale of 1.3, the window title takes 2 lines in every tile, so the tiles of 1 row keep the same height. A player tile also has a round play and pause button in green.

### Window title

A status dot and a state word in the state color, then " · " and the source in mono and `sub`. For example: "Needs input · codex · billing". The state comes first, so that a cut removes only the end of the source. The state word carries the meaning, so the color is never the only signal.

### Tools

- **Master tool:** The tool that a destination uses most, such as Send clipboard. It is at least 128 dp high, on `tile-hi` with a `line-hi` border. A 28 dp accent icon sits at the top, and a 20 sp label sits at the bottom.
- **Tool row:** A row of at least 56 dp with a 22 dp accent icon, a 15 sp label, and a 13 sp `sub` line. A tool that is off has a `sub` icon and shows at 55% alpha.

### Preserved surfaces

The pairing sheet, `TiledPairSheet`, and the fingerprint approval screen, `ApproveActivity`, keep their layout and behavior. Their colors follow the theme. Do not restyle them as part of a system change.

## Do's and Don'ts

### Do:

- **Do** take every color from a `Tn` role, and check new pairs with the contrast guard in Tokyo Night and Tokyo Night Day.
- **Do** put the most urgent item in the master tile with its whole action, and keep its choices at thumb height on a phone.
- **Do** keep the lines nearest the choices in an agent prompt, so that a one-tap choice never approves a command that the user cannot see.
- **Do** use 8 dp gaps, a 10 dp gutter, and 12 dp corners for tiles.
- **Do** set computer data in mono and Flux text in Roboto.
- **Do** give every control a 48 by 48 dp target, a TalkBack role, and a state.
- **Do** give state in words as well as in color, as the window title does.
- **Do** use 200 ms with the standard easing for shell motion, and no motion when Remove animations is on.

### Don't:

- **Don't** use red for anything other than "needs you", errors, and the Destructive button kind.
- **Don't** put the active border gradient on any tile other than the tile in the master position.
- **Don't** hard-code a color value in a screen.
- **Don't** use `dim` for text that carries meaning.
- **Don't** add shadows to tiles.
- **Don't** build a device list, then a grid of feature cards for each device.
- **Don't** change the layout or behavior of the pairing sheet or the fingerprint approval screen.
