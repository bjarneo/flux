---
name: Flux for Android, iOS, macOS, and Windows
description: The device side of Flux. 1 chat of the computers and the device, with what needs the user in the thread, in the live Omarchy theme of the computer.
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

# Design System: Flux for Android, iOS, macOS, and Windows

## Overview

**Creative North Star: "The Thread of What Needs You"**

Flux for Android looks like the user's own Omarchy desktop. Tiles sit on the page with Hyprland gaps. **Chats** holds 1 chat for each agent and each computer, with what needs the user on top. The chat of a computer shows what happens between the phone and that computer as 1 thread, with the newest entry at the bottom. A card that needs the user takes the full width and a red border, and it holds its whole action. Flux for iOS, Flux for macOS, and Flux for Windows show the same chats.

The app has no palette of its own. The colors come from the live Omarchy theme of the computer in scope, through a contrast guard. Tokyo Night is the fallback when no computer sent a theme. The token values in this file are the Tokyo Night reference set. The roles are the system, and the values change with the theme.

The density is that of a tiled desktop: 8 dp gaps, 12 dp corners, flat tiles, and no shadows. Mono sets what the computer says, such as window titles, prompts, keys, and data. Roboto sets what Flux says. The app rejects the category default of a device list, then a grid of feature cards for each device.

Flux for iOS and Flux for macOS use the same system. They share the token roles, the contrast guard, the Tokyo Night fallback, the chat order, the window title with the state word first, and the one-tap rule for agent choices. The Android app is the reference for every section. The section "Apple platforms" gives only what differs on iOS and macOS. That section comes from the Swift code, because no capture of the Apple apps exists yet.

Flux for Windows uses the same system with the macOS metrics. The section "Windows" gives what differs. It comes from the C# code in `windows/Flux`.

**Key Characteristics:**

- The colors are roles from the theme of the computer, not fixed values.
- Every role pair reaches WCAG 2.2 AA in every theme: 4.5:1 for text, and 3:1 for icons and borders.
- 1 chat thread in time order. A card that needs the user takes the full width and a red border.
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
- **Done Green**, `green`: A connected link dot, an agent that is done, a finished transfer, a player that plays, a battery that charges, and a live camera or microphone, as in the stream notice of the chat.
- **Clipboard Cyan**, `cyan`: The clipboard item, a battery above 50%, and the second stop of the fallback border gradient.
- **Warning Yellow**, `yellow`: A battery at 50% or less, the notification notice of the chat, and the top edge of the pairing sheet.
- **Low Orange**, `orange`: A battery at 20% or less.
- **Theme Magenta**, `magenta`: The tertiary role of the Material scheme. It has no Flux meaning of its own.
- **Terminal Blue**, `termBlue`: The blue of the theme for ANSI blue in agent output. It can differ from the accent. It has no frontmatter token because Tokyo Night uses the accent value.

### Neutral

- **Page**, `bg`: The page, the sheet surface, and the fill of an unselected choice row in the master.
- **Off Tile**, `off-tile`: A tile that is off, the agent output, and the command block.
- **Tile**, `tile`: The default tile, the chat card, the scope chip, and the square buttons.
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

- **Empty title**, 600, 22 sp: The title of the pairing guide and the media title of Media.
- **Master title**, 600, 20 sp: The label of a master tool.
- **Card title**, 600, 14 sp, line height 1.3: The title of a chat card. A file name or a clip uses mono.
- **Top bar title**, 600, 18 sp, line height 1.2: The title of a feature screen. TalkBack reads it as a heading.
- **Tool label**, 600, 15 sp: The label of a tool row, an action tile, and a computer row.
- **Section label**, Material 3 Title Small, 500, 14 sp: The heading of a group of tiles, in sentence case.
- **Body**, 400, 14 sp, line height 1.35: Descriptions and the choice labels.
- **Button**, 600, 14 sp: Every `FluxButton` label.
- **Secondary**, 400, 13 sp, line height 1.3: The line under a tool label, and error text.
- **Tile label**, 500, 12 sp, line height 1.35: The label of a value or a group in a tile, in `sub`.
- **Prompt**, mono 400, 14 sp, line height 1.35: The question of an agent and a clipboard preview.
- **Window title**, 12 sp: The top row of a chat card: the state word in Roboto 500 and the state color, then the source in mono and `sub`, and the time in mono 11 sp.
- **Thread message**, 400, 14 sp, line height 1.5: A message of an agent on the agent screen. Paths and code show in mono 12 sp on `tile`.
- **Dock question**, 600, 16 sp: The question of a blocked agent in the dock of the agent screen.
- **Choice key**, mono 700, 15 sp, in the accent: The digit of an agent choice.
- **Data**, mono 400, 12 sp to 13 sp: The computer name, the top bar context line, the user and TTY of an approval, file names, keys, and badges.

All text grows with the Android font size. Layouts hold at 200%. A key label shrinks to fit its key, to half its size at most. The navigation labels stop at a font scale of 1.5.

### Named Rules

**The Mono Is the Computer Rule.** Set text in mono only when it comes from the computer: window titles, prompts, commands, keys, file names, and data. Set Flux sentences, labels, and headings in Roboto.

**The Sentence Case Rule.** Write labels and headings in sentence case, as written. Do not use all caps or letter spacing for labels.

## Layout

Each app shows **Chats** as its first destination.

- **Gaps and gutter:** Tiles keep an 8 dp gap. The screen gutter is 10 dp. The shell top bar starts 5 dp further in, to align the Flux mark.
- **Phone in portrait:** **Chats** is a list. The chat of a computer is 1 thread with the newest entry at the bottom, and the dock under it. Cards of a computer sit on the left at 88% of the width. A card that needs the user takes the full width. What the phone sent sits on the right.
- **Wide window, 600 dp and more:** A navigation rail replaces the navigation bar. The dock of each screen becomes a tile at the bottom of a column on the right, at thumb height. The tray of a chat opens in the dock tile. **Live** keeps the dock in that column, and the terminal takes the full height. The arrow of **Waiting for you** points to the dock at the side.
- **Tablet in landscape:** A wide window that is not short splits **Chats**: the list is 380 dp wide at the start, a 1 dp `line` rule follows, and the chat of the selected computer or agent takes the rest. The row of that chat takes `accent-tile`. Without a selection, the side tells the user to select a chat. A screen that a chat opens, such as the camera, covers the full window.
- **Short window:** The dock of a chat takes at most 70% of the height, and it scrolls inside that part.
- **Content width:** Screens other than the chats scroll in `CappedScrollColumn`. The content is at most 840 dp wide and stays in the center.
- **Destinations:** Chats, Control, and Computers. Control opens with 1 master tool, then groups of tool rows under section labels. In Control, the agent rows come right after the master tool, because the user needs them most often.
- **Order:** **Chats** puts what needs the user first, the newest first, then the agents that work, are done, and are idle, then the computers, online first. See `chatList` in `core/ChatList.kt`. The chat of a computer puts its entries in time order, see `chatItems` in `core/ChatFeed.kt`.
- **Targets:** Every control takes taps on at least 48 by 48 dp.

## Elevation & Depth

The system is flat. Tiles have no shadows. Depth comes from 4 tonal surface steps, `bg`, `off-tile`, `tile`, and `tile-hi`, and from 1 dp borders in `line`. In a dark theme, the tiles are lighter steps of the page. In a light theme, they are darker steps. The only emphasis beyond tone is the 2 dp red border of a card that needs the user, and the 2 dp active border gradient of the pairing guide.

### Named Rules

**The Flat Tile Rule.** Do not add a shadow to a tile. To raise a tile, step its fill to `tile-hi` and its border to `line-hi`.

**The One Active Window Rule.** Only the pairing guide carries the active border, as the focused window does in Hyprland. A chat card that needs the user takes a 2 dp red border instead. The gradient is the `hyprland_active_border` colors of the theme at its angle. Without a theme border, it goes from the accent to cyan, corner to corner.

## Shapes

The corners follow the Omarchy window: 12 dp on tiles, buttons, fields, and the field key. Smaller parts inside a tile take 8 dp: choice rows, choice chips, square buttons, the command block, and the count badge. The scope chip takes 10 dp. Sheets take 20 dp at the top corners. Status dots, link dots, and round media controls are circles. A computer that is available to pair has a dashed border of 1.5 dp, with 6 dp dashes and 5 dp spaces.

A pressed tile changes its border to the accent. A selected choice changes its border to 2 dp of the accent. A tile or choice that takes no taps shows at 55% alpha.

## Components

### Buttons

`FluxButton` with `ButtonKind` is the 1 button of the app.

- **Shape:** The tile corner, 12 dp. The button is at least 48 dp high, and its label wraps at a large font size.
- **Filled:** The accent fill with `on-accent` text. Use it for the main action of a screen or a tile.
- **Tonal:** The `line` fill with `text`. Use it for a second action that needs weight, such as Stop or Done.
- **Outlined:** A 1 dp `dim` border with accent text. Use it for a second action, such as Show Downloads on a transfer.
- **Destructive:** A 1 dp red border with red text. Use it for an action that ends or deletes something for good.
- **Text:** Accent text with a 12 dp side inset. Use it for a small action in a line of text, such as Retry. Open thread and Open on a chat card are accent text with no inset, 13 sp, 600.
- **States:** A busy button shows a spinner in the place of its icon, keeps its colors, and takes no taps. A disabled filled or tonal button takes the `tile` fill and `dim` text.

### Chips

- **Scope chip:** A `tile` chip with a 10 dp corner and a `line` border, 40 dp high, that takes taps on 48 dp. It shows "All computers" or 1 computer, then a 7 dp link dot for each computer, then an expand icon. A tap opens the scope menu.
- **Choice chip:** A choice of a small group, such as a player or a camera mode. It is at least 40 dp high and takes taps on 48 dp. The label is 13 sp, 600, in `sub`. A selected chip takes `accent-tile`, a 2 dp accent border, and `text`.

### Cards / Containers

- **Corner Style:** 12 dp. A chat card has 14 dp, with a 4 dp corner at the bottom left.
- **Background:** `tile` by default, `tile-hi` for the master tool, and `off-tile` for a tile that is off.
- **Shadow Strategy:** None. See Elevation & Depth.
- **Border:** 1 dp `line`. A chat card that needs the user has a 2 dp red border.
- **Internal Padding:** 14 dp for a tile, 12 by 10 dp for a chat card, 18 dp for the master tool, and 20 dp for the pairing guide.

### Inputs / Fields

- **Style:** The Material 3 outlined field on the tile corner, with 14 sp text in `text`. The placeholder is in `sub`. A field for a command uses mono.
- **Focus:** The border changes from `dim` to the accent.
- **Field key:** The Send or Run key at the end of a field is a 56 dp square on the tile corner. It takes the accent fill while it can send, else the `tile` fill with a `line` border.

### Navigation

- **Bar:** A 66 dp bar on `bg` in a compact window, with 3 destinations: Chats, Control, and Computers. Each has a 22 dp icon in a 56 by 30 dp pill, and a 12 sp label. The pill of the open destination takes `line`, and its label is 600 in `text`. The Chats pill shows a red badge with the number of items that need the user, up to "9+". The bar shows on each destination. A swipe to the side also moves between the 3 destinations. The chat of a computer or an agent is a feature screen above Chats, so it has no bar.
- **Rail:** The Material 3 navigation rail in a window of 600 dp and more, with the same destinations.
- **Top bar:** A destination shows the Flux mark, its title, and a mono context line. **Chats** ends the row with the 48 dp **+** key. A feature screen shows a 40 dp back button, the title, and an optional mono context line. When the actions leave the title too little width, they move to a second row. A chat has its own top bar, see Chat.
- **Motion:** Destinations fade through in 240 ms. A feature screen moves on the horizontal axis in 220 ms. Predictive back follows the gesture.

### Chats

The signature component: 1 chat for each agent and each computer, as in a messaging app.

- **Header:** The Flux mark, Chats in 16 sp 600, the count of what needs the user and the computers online in mono 11 sp, and the 48 dp **+** key that starts an agent or a terminal.
- **Search:** A 44 dp pill on `tile` with a `line` border, a 20 dp search icon in `sub`, and the placeholder "Search agents, computers, files". It keeps only the chats that hold its text. A computer also stays when an entry of its chat holds it.
- **Groups:** Needs you, Agents, and Computers, each with a 14 sp 500 heading and a mono 11 sp line at the end: the count in red, or the computer of the agents.
- **Row:** A 44 dp picture with 12 dp corners, the title in 15 sp 600 on 1 line, the line under it in 12 or 13 sp, and the time in mono 11 sp `sub` at the end. The picture is `tile` with a `line` border and a 22 dp icon. A 12 dp dot at its bottom right, with a 2 dp ring of the ground, shows the state: green for online or done, red for needs input, and `dim` for idle. An agent that works shows a turning ring in the place of the dot.
- **Agent row:** The task as the title, then the window title: the state word in the state color and " · agent · project" in mono `sub`. An agent that waits takes `tile`, a 1 dp red border, and an `accent-tile` picture, and shows how long it waits, such as "3m". An agent that works shows how long it works, such as "2:14".
- **Computer row:** The name, and the newest entry of its chat, such as "You: Dinner at 7". A computer that is not reachable shows at 55% with "Offline · last seen 09:12".
- **Approval and pair request:** A card on `tile` with 12 dp corners and a 2 dp red border, with Deny and Approve, 44 dp high. Approve opens the approval screen.

### Agents widget

The home screen widget of Android: the Needs you and Agents groups of Chats, without the computers. The code is in `widget/`.

- **Ground:** `bg` with the corner of the launcher, 16 dp before Android 12. The inset is 8 dp. It has no shadow and no border.
- **Header:** 36 dp: the 20 dp Flux mark in `text` and the accent, **Agents** in 15 sp 600, then the count in red mono 11 sp and " · 1 of 2 online" in `sub` mono 11 sp at the end. A widget narrower than 240 dp hides the title and the online count. The mark is `dim` while no computer can send agents. A tap opens Chats.
- **Row:** At least 48 dp high, with 4 dp between rows and a 10 dp inset. A 10 dp dot, the task in 14 sp 600 on 1 line, the computer in mono 11 sp `sub` at the end of the task, and under them the state word in 12 sp 500 in the state color and " · agent · project" in mono 12 sp `sub`. A narrow widget puts the computer at the end of the source. Below 180 dp, the row shows no source. The dot is red, green, or `dim`. An agent that works has a 2 dp ring in the accent that does not turn.
- **Needs you:** An agent that waits takes `tile` and a 1 dp red border on 12 dp corners. An approval and a pair request take a 2 dp red border. The widget has no buttons: a tap opens the chat or the approval screen.
- **More:** When not all rows fit, a 24 dp line in 12 sp `sub` at the end says "3 more in Chats". When that line would take the place of a row, the header says "3 more" in the place of the computers online.
- **Quiet state:** With no rows, a title in 14 sp 600 and a line in 12 sp, both in `sub`, such as "No computer is connected". The quiet state has no red.
- **Colors:** The roles of the theme of all computers through the contrast guard: `text`, `sub`, red, green, and the accent on `bg` and `tile`, and `dim` only for the dot and the mark. `WidgetModelTest` checks each pair in each sample theme.

### Chat

The chat of 1 computer: 1 thread of the computer and the device.

- **Top bar:** A 48 dp back icon, a 36 dp picture with 10 dp corners and an 11 dp state dot, the name in 16 sp 600, the link and battery in mono 11 sp, and the menu: Control, Agents and terminals, and New agent or terminal.
- **Progress:** A 2 dp `line` rule under the top bar. A file that comes in or goes out fills it in the accent.
- **Card of a computer:** `tile` with 14 dp corners and a 4 dp corner at the bottom left. The top row holds the state mark and word, the source in mono, and the time. A 14 sp 600 title, a mono 12 sp body in `sub`, and a 13 sp accent text action follow.
- **Card that needs the user:** An approval takes the full width and a 2 dp red border. It shows Deny and Approve, 48 dp high. Approve opens the approval screen.
- **What the phone sent:** A bubble on `accent-tile` with a `line-hi` border, 16 dp corners, and a 4 dp corner at the bottom right, at most 82% of the width. Text is in 14 sp. A link or a clip is in mono 12.5 sp. A photo is a 220 by 132 dp picture with the same corners. Another file is a 236 dp card.
- **Dock:** The phone clipboard in a 40 dp row on `bg` with 10 dp corners: an 18 dp cyan clipboard icon, the source in 10 sp cyan, the clip in mono 12 sp, and Send as a 13 sp accent text action. Then the composer: a 48 dp round **+** key in `line`, the field, the 48 dp mic key, and the 48 dp send key. The send key shows the number of selected photos in an 18 dp `text` circle.
- **Tray:** **+** opens the tray under the composer, and turns into an accent key with a cross. The tray holds Recent photos with All photos, the 4 newest photos as 80 dp cells with 10 dp corners, and the tools as 64 dp cells on `bg` with a `line` border, 4 in a row. A selected photo takes a 2 dp accent border and its number in a 20 dp accent circle. The tray and the keyboard take the same place, so 1 closes the other. Back closes the tray.
- **Field:** While the field has the focus, **+** hides and the field grows to 6 lines with an accent border. While the phone listens, the panel of the dictation takes the full width.

### Agent screen

The agent screen shows 1 herdr agent as a thread. `agentThread` in `core/AgentThread.kt` reads the output of Claude Code, Codex, and opencode. Lines that it does not know stay terminal lines.

- **Top bar:** The top bar of a chat: a 48 dp back icon, a 36 dp picture on `accent-tile` with the state dot, the task in 16 sp 600, and the agent, the project, and the computer in mono 11 sp. Live is a 36 dp pill. The Changes key is a 48 dp icon. The menu holds Refresh, Show keys, and Close the agent.
- **Progress:** A 2 dp `line` rule under the top bar. While the agent works, a bar of 40% of the width slides over it in the accent.
- **Thread:** Messages, tool calls on `off-tile` with a 12 dp corner, a changes card on `tile`, and prompts as bubbles on `accent-tile`. A tap on a tool call shows its result.
- **Dock:** `tile` with 20 dp top corners and a `line` rule at the top. It lies 14 dp over the end of the thread. It shows the question with 48 dp choices, the step of a working agent with Interrupt, or the end of a turn. The composer is a 48 dp pill on `bg` with a `line-hi` border, a round mic key on `line`, and a round accent send key.
- **Changes sheet:** `tile` with 20 dp top corners. Each file is a card on `bg` with its diff lines in mono 11 sp: hunks in cyan, added lines in green, and removed lines in red.

### Window title

A status dot and a state word in the state color, then " · " and the source in mono and `sub`. For example: "Needs input · codex · billing". The state comes first, so that a cut removes only the end of the source. The state word carries the meaning, so the color is never the only signal.

### Tools

- **Master tool:** The tool that a destination uses most, such as Send clipboard. It is at least 128 dp high, on `tile-hi` with a `line-hi` border. A 28 dp accent icon sits at the top, and a 20 sp label sits at the bottom.
- **Tool row:** A row of at least 56 dp with a 22 dp accent icon, a 15 sp label, and a 13 sp `sub` line. A tool that is off has a `sub` icon and shows at 55% alpha.

### Preserved surfaces

The pairing sheet, `TiledPairSheet`, and the fingerprint approval screen, `ApproveActivity`, keep their layout and behavior. Their colors follow the theme. Do not restyle them as part of a system change.

The SSH key screen, `SshSignActivity`, uses the layout and the guards of the approval screen: the 88 dp key badge, the question, the computer, the program in mono in a box, the red warning, and Deny and Approve. The program comes from the computer, so it stays in its box and never joins the question. The **SSH key** page under Computers uses the sync switch row, a `tile` with the public key and the fingerprint in mono, and the command block.

## Apple platforms

Flux for iOS and Flux for macOS use the system of this file. This section gives only what differs from Android. All other sections apply to the 3 apps.

This section comes from the Swift code. No screen capture of the Apple apps exists yet. Check the values against a build before you change a token for them.

### Shared code

- **Theme engine:** `macos/Sources/FluxKit/Theme/ThemePalette.swift` is the port of `paletteOf`. It has the same contrast needs: 4.5:1 for text, and 3:1 for icons and borders. It has the same Tokyo Night and Tokyo Night Day values as the frontmatter and the light reference.
- **Theme setting:** `ThemeMode` has the 4 choices Computer, System, Light, and Dark. In the scope of all computers, `ThemeBook` uses the theme that changed most recently.
- **Agent thread:** `macos/Sources/FluxKit/Plugins/Herdr/AgentThread.swift` is the port of `core/AgentThread.kt`: `AgentThread.parse`, `AgentAsk.find`, `AgentAsk.dialogStart`, and `DiffFile.parse`. `AgentThreadTests` holds the same cases as the Kotlin tests, so both give the same thread.
- **Chat:** `macos/Sources/FluxKit/Inbox/` holds `Chat.entries`, the port of `chatItems` on Android, with `SeenClock`, `Chat.isTellChoice`, the Inbox items, and `Inbox.agentPrompt`. The agent prompt keeps the lines nearest the choices, so that a one-tap choice never approves a command that the user cannot see.
- **Roles in a view:** `ThemeColors` in `App/Theme/ThemeKit.swift` gives each role as a SwiftUI color through `@Environment(\.tn)`. `ThemeRoot` puts the palette into the environment and sets the tint to `accent`. Use a `tn` role where Android uses a `Tn` role.
- **Shell kit:** `App/Theme/TiledKit.swift` holds `TiledMetrics`, the tile, `ActiveBorder`, `FluxButtonStyle` with the 5 kinds, `MasterTool`, `ToolRow`, `SectionLabel`, `NeedsBadge`, `LinkDot`, `BatteryDot`, `FluxSpinner`, `LineSkeleton`, and `CommandBlock`. iOS and macOS each have their own copy, with the metrics of the platform.

### Shared Apple rules

- **Type faces:** The system font, SF Pro, sets Flux text. The monospaced design, SF Mono, sets computer data. The Mono Is the Computer Rule applies with SF Pro in the place of Roboto.
- **Window title:** The same form as on Android: a dot and the state word in the state color, then " · " and the source in mono and `sub`, and the time. VoiceOver reads the top row as 1 line.
- **Secret clip:** A clip that is a secret shows "Hidden text", `ClipEvent.hiddenText`. The text is in the body face, not in mono, because it is Flux text and not computer data. The event keeps no part of the secret. An image clip shows "An image".
- **Active border:** 2 pt on the 12 pt tile corner. 1 border color gives a solid stroke. Without a theme angle, the gradient goes from the top left corner to the bottom right corner.
- **Motion:** `Motion.standard` is 200 ms with the standard easing, `cubic-bezier(0.4, 0, 0.2, 1)`, or no motion with Reduce Motion. With Reduce Motion, the spinner is a fixed ring of 3 quarters and the skeleton does not pulse.
- **Feature pages and windows:** `fluxScreen()` gives a page the theme background, the accent tint, and the light or dark mode of the theme. The inside of a feature keeps its own colors. The raw terminal lines of an agent keep their terminal colors.
- **Agent thread views:** `App/Features/Agents/AgentThreadViews.swift` in each app holds the parts of the Android agent screen: `RingSpinner`, `PulseDot`, `SlideBar`, `AskChoiceButton`, `CodeLines`, the thread blocks, and `ChangesSheet`. The dock has 20 pt top corners and lies under the thread. The first choice takes the accent fill, and the other choices take `line`.
- **Preserved surfaces:** The pairing views and the approval prompt keep their layout and behavior. They take only the accent and the light or dark mode of the theme. Do not restyle them as part of a system change.

### iOS

The iPhone app follows the HIG structure. The code is in `ios/App/`.

- **Navigation:** A `TabView` with 3 tabs: Chats, Control, and Computers. Chats uses the `text.bubble` symbol. The Chats tab shows a badge with the number of items that need the user on all computers, from 1 to "9+". Each tab has its own `NavigationStack`, with the system back button and the edge swipe. A tap on the open tab goes back to its root. The tab bar shows on each tab root. The chat of a computer and the chat of an agent push onto the stack of Chats and hide the tab bar. A swipe to the side does not change the tab.
- **Bars:** The tab bar takes the `tile` fill. The navigation bar of a tab root takes the `bg` fill and an inline title. The Flux mark, the title, and the mono context line take the place of the visible title. A chat takes the `bg` fill too, a back key without a label, and its `ChatTitle` in the middle: the 36 pt picture with 10 pt corners and an 11 pt state dot, the title in subheadline semibold, and the context line in caption 2 mono. The title stays for VoiceOver and the back button.
- **Chats:** `ChatsView` follows the Android Chats. The navigation bar holds the title, the context line, and the **+** key. The search field is a 44 pt capsule on `tile` with a `line` border, and it takes the accent border while it has the focus. It stays at the top while the list scrolls. A row is a button with a 44 pt `ChatAvatar`, the title in subheadline semibold, the line in caption or footnote, and the time in caption 2 mono. The approval and a pair request use the cards of the chat with tile corners and 44 pt buttons. An agent uses the `brain` symbol, and a computer uses the symbol of its type.
- **Chat:** `ComputerChatView` holds the chat of 1 computer. The menu of the navigation bar holds Control, Agents and terminals, New agent or terminal, and Queue and transfers. The thread and the dock follow the Android chat, without agent cards. Open on a received file shows it with Quick Look. The clipboard row has a 44 pt Send target. The tray reads the 4 newest images with PhotoKit only when Flux has access to the photos. Without the access, a row on `bg` asks for it. All photos opens `PhotosPicker`. The tools are 64 pt cells on `bg` in a grid of 4.
- **Metrics:** An 8 pt gap, a 10 pt gutter, a 12 pt tile corner, an 8 pt small corner, and a 10 pt chip corner. The content is at most 840 pt wide, and the choice and action rows are at most 600 pt wide.
- **Targets:** Every control takes taps on 44 by 44 pt or more. A `FluxButton` is 44 pt high or more. A choice is 48 pt high or more in the dock. The buttons of an approval are 48 pt in a chat and 44 pt in Chats. A tool row is 56 pt high or more. The master tool is 128 pt high or more. The round media buttons are 48 pt, and the main one is a 56 pt green circle.
- **Type:** System text styles, so Dynamic Type works from xSmall to the accessibility sizes. Icons scale with the body style.

| Role | iOS text style |
| --- | --- |
| Card title | Subheadline, semibold. A file name or a clip uses mono. The media title is Title 2, semibold. |
| Tool label | Subheadline, semibold. The master tool label is Title 3, semibold. |
| Section label | Subheadline, medium |
| Body and button | Subheadline. The button label is semibold. |
| Secondary | Footnote |
| Prompt | Subheadline, mono |
| Choice key | Subheadline, mono, bold, in the accent |
| Window title | Caption. The state word is medium. |
| Data | Caption, mono, for the computer name. Footnote, mono, for approval data and the command block. |
| Badge | Caption, mono, bold |

- **States:** A pressed tile changes its border to the accent, as on Android. A pressed `FluxButton` shows at 70% alpha.
- **VoiceOver:** Each control has a label, a value, and a hint. The top row of a chat card reads the state, the source, and the time as 1 line.
- **Agent screen:** The navigation bar has the look of a chat: the 36 pt picture on `accent-tile` with the state dot, the task, and the agent, the project, and the computer in mono. The Changes key and a menu with Refresh, Show keys, and Close the agent follow. The progress line, the thread, and the dock follow the Android agent screen. The Changes sheet is a large sheet on `tile`. iOS has no Live.
- **Differences from Android:** A tab bar in the place of the navigation bar and the navigation rail. A wide window keeps the tab bar. A swipe does not move between the tabs. The chat of a computer has no Copy on a clip, and a sent photo shows as a file card. The system push and back motion in the place of the 220 ms shared axis and predictive back. 44 pt targets in the place of 48 dp targets. Text styles in the place of fixed sp sizes.
- **Preserved surfaces:** The pairing sheet, `PairSheet`, and the Face ID approval sheet, `ApprovePrompt`.

### macOS

The Mac app follows the macOS 14 structure. The code is in `macos/App/`.

- **Main window:** A `NavigationSplitView`, at least 800 by 520 pt. The default size is 1000 by 660 pt. The sidebar is 260 pt to 420 pt wide, 300 pt by default. It holds the list of chats, then the rows of Control and Computers with their keys, and this Mac at the bottom. The detail column shows the open chat, Control, or Computers, each with its own `NavigationStack`. The design note says it: macOS puts the list in the sidebar and the chat in the detail column.
- **Toolbar:** The scope menu sits in the toolbar of Control and Computers. It is a chip with the chip corner, a link dot and a battery dot for each computer, and a chevron. A click opens a panel of choices, 280 pt wide, with rows of 36 pt. Chats has no scope.
- **Go menu:** Command-1 to Command-3 open Chats, Control, and Computers. Chats shows the chat that was open last. Command-R and Command-D stay with the agent chat and the agents window.
- **Chats:** The sidebar follows the Android list. The header holds the Flux mark in the accent, Chats in 15 pt semibold, the count of what needs the user and the computers online in mono 11 pt, and a 28 pt round **+** key on `line` that starts an agent. The search field is a 30 pt pill on `tile` with a `line` border, and the border takes the accent while the field has the focus. The group headings are 13 pt medium with the trailing text in mono 11 pt. A row has a 36 pt picture with 10 pt corners and an 11 pt dot, the title in 13 pt semibold, and the line in 12 pt. The open chat takes `line`, and a hover adds 5% of `text`. An agent that waits takes `tile`, a 1 pt red border, and an `accent-tile` picture. The approval and the pair request are cards on `tile` with the tile corners and a 2 pt red border, with 40 pt buttons. The agent symbol is `brain`, as in the rest of the Mac app.
- **Chat of a computer:** The window toolbar holds a 28 pt picture with the state dot, the name as the title, the link and battery as the subtitle, and a menu: Control, Agents Window, Start an Agent, and Computer Page. The thread column is at most 840 pt wide, and the dock lies under it. The thread holds no agents. The clipboard row is 40 pt on `bg` with 10 pt corners, a cyan icon, and Send as a text action.
- **Tray:** The 34 pt **+** key opens the tray under the composer, and turns into an accent key with a cross. The tray holds the tools as 52 pt cells on `bg` with a `line` border, 4 in a row: Camera, File, Scan, Text, QR, Signature, Get files, and Agent. The Mac has no photo library tray. While Send new screenshots is on, the tray shows the 4 newest screenshots as 64 pt cells with 10 pt corners, and All screenshots. A selected screenshot takes a 2 pt accent border and its number in an 18 pt accent circle, and the send key shows the count in a 16 pt `text` circle. A click in the field or Escape closes the tray.
- **Agent chat:** The agent thread and dock of the agents window in the detail column. The window toolbar holds a 28 pt picture on `accent-tile` with the state dot, the task as the title, the agent, the project, and the computer as the subtitle, then Changes, Keys, Copy, and Refresh.
- **Metrics:** An 8 pt gap, a 12 pt gutter, a 12 pt tile corner, an 8 pt small corner, and a 10 pt chip corner. The content is at most 840 pt wide, and the choice and action rows are at most 600 pt wide.
- **Agents window:** It stays for Agents Window in Control, Agents in the menu bar panel, Open Agents on the page of a computer, and the agent notifications. The agent list stays in the sidebar in the place of the strip of pills. The detail shows a header with a 32 pt agent picture, Changes, Command-D, a Keys toggle, Copy, and Refresh, Command-R. The progress line, the thread, and the dock follow the Android agent screen. The Changes sheet closes with Escape. The Mac has no Live.
- **Targets:** A button is 28 pt high or more. Choice rows are 36 pt high or more. A tool row is 44 pt high or more. Every action is a `Button`, so Tab and Space reach it with full keyboard access.
- **Buttons:** `FluxButtonStyle` has the same 5 kinds as Android, on the 8 pt small corner. The label is 13 pt semibold, with 14 pt side insets, or 8 pt for the Text kind. A hover adds 6% of `text` over the button. A press shows the button at 80% alpha.
- **Tiles:** A pressed tile shows at 80% alpha. Its border does not change to the accent.
- **Type:** Fixed point sizes on the system font.

| Role | macOS size |
| --- | --- |
| Card title | 13 pt, semibold. A file name or a clip uses mono. The media title is 20 pt, semibold. |
| Tool label | 13 pt, semibold, with an 11 pt line. The master tool label is 17 pt, semibold, with a 13 pt line. |
| Section label | 13 pt, medium |
| Body and status line | 13 pt |
| Secondary | 12 pt |
| Prompt | 13 pt, mono |
| Choice key | 13 pt, mono, bold, in the accent |
| Window title | 11 pt. The state word is medium. |
| Data | 11 pt mono for the computer name, 12 pt mono for the command block |
| Badge | 11 pt, mono, bold |

- **Menu bar extra:** The Flux mark, then the count of items that need the user, from 1 to "9+". The mark has an offline form when no computer is connected. VoiceOver reads "Flux, 2 items need you". The extra uses the window style, so its panel reads the agent output when it opens.
- **Menu bar panel:** 360 pt wide with a 12 pt inset. It shows a red dot and the count line, then the 2 newest items that need the user as chat cards with their one-tap choices. A choice that rejects the action and Open chat open the chat of the agent in the main window. Under them are up to 3 rows that open their chats, a menu for each online computer, and Open Flux, Settings, and Quit Flux. The panel does not use the scope.
- **Destinations:** Control opens with the master tool Remote desktop, and the agents row comes right under it.
- **Settings window:** It holds the theme under General, Theme, and the feature settings. It takes the theme surfaces.
- **Feature windows:** The windows for agents, browse, camera, remote desktop, and touchpad keep their layout. They take the theme background, the accent, and the light or dark mode.
- **Differences from Android:** The list of chats in the sidebar and the open chat in the detail column, in the place of the navigation bar and a screen for each chat. The chat top bars in the window toolbar. A tray with recent screenshots in the place of recent photos. 28 pt pointer targets in the place of 48 dp touch targets. A hover state. Buttons on the 8 pt small corner. A pressed tile dims and keeps its border. A 12 pt gutter. The menu bar extra exists only on the Mac.
- **Preserved surfaces:** The pairing view shows on the theme background of the window, and takes the accent and the light or dark mode. The pair request sheet, `PairRequestSheet`, and the Touch ID approval window, `ApprovePrompt`, keep their own background, and take only the accent and the light or dark mode.

## Windows

Flux for Windows uses the system of this file with the metrics of macOS, because both are pointer desktops. This section gives only what differs from macOS. All other sections apply.

This section comes from the C# code in `windows/Flux`. No capture of the Windows app exists yet.

### Shared code

- **Theme engine:** `windows/FluxKit/Theme/ThemePalette.cs` is the port of `ThemePalette.swift`, with the same contrast needs and the same Tokyo Night and Tokyo Night Day values. `ThemeMode` has Computer, System, Light, and Dark.
- **Roles in a view:** `ThemeColors` in `windows/Flux/Kit/Tn.cs` gives each role as a frozen WPF brush through `Tn.Current`. `Tn.Changed` draws the open views again.
- **Shell kit:** `windows/Flux/Kit` holds `Metrics`, `Faces`, `Stack`, `FluxButton` with the 5 kinds, and `Parts`: the master tool, the tool row, the grid tool, `SectionLabel`, `ListHeading`, `NeedsBadge`, `LinkDot`, `BatteryDot`, `RingMark`, the spinner, the progress line, `KeyView`, `CommandBlock`, and the page dock.
- **Views in code:** The views are C# code, not XAML. A view draws itself from the models again after a change, as a SwiftUI view does. Fields and lists that keep their state stay across the drawings.

### Windows rules

- **Type faces:** Segoe UI Variable Text, or Segoe UI, sets Flux text. Cascadia Mono, or Consolas, sets computer data. Segoe Fluent Icons, or Segoe MDL2 Assets on Windows 10, draws the icons. The Mono Is the Computer Rule applies with Segoe UI in the place of Roboto.
- **Main window:** At least 820 by 520 px, 980 by 640 px by default. The sidebar is 300 px wide. At the top, it holds the Flux mark, the word `flux` in mono, and the **+** key that starts an agent. The list of Chats follows. Control and Computers sit under a `line` rule, and this computer is at the bottom. The selected destination takes a `line` fill and a 600 label. The detail column shows the open chat, or the page of Control or Computers.
- **Chats:** The list of the Chats section, in the sidebar and in the macOS sizes. The title is 15 px 600, and the context line is mono 11 px. The search is a 32 px pill on `tile` with a `line` border, the clear key, and the mic key. With the focus, its border takes the accent. The group headings are 13 px 500, with the count or the computer in mono 11 px. A row has a 36 px picture with 10 px corners and a 12 px state dot. The title is 13 px 600, the line is 12 px, and the time is mono 11 px. The open chat takes a `line` fill. The approval and the pair request are cards with the tile corner and 40 px buttons.
- **Chat:** The top bar of a chat replaces the header. It holds the 36 px picture with the state dot, the name in 15 px 600, the link and battery in mono 11 px, and the menu key. The list stays in the sidebar, so the top bar has no back key. The clipboard row is 40 px high. The **+** key, the field, the mic key, and the send key are 36 px. The tray opens in the dock with Recent screenshots and All screenshots. The 4 newest screenshots are 72 px cells, and the tools are 60 px cells on `bg`, 4 in a row. The tray scrolls inside 280 px, and Escape closes it.
- **Agent chat:** The agent screen with the top bar of a chat: the picture on `accent-tile`, the task, and the agent, the project, and the computer in mono. `±` opens the changes, then Keys, Copy, and Refresh.
- **Header:** The title of the page in 15 px 600, the context line in mono 11 px and `sub`, a back button on a route, and the scope chip on a destination root. A chat draws its own top bar.
- **Title bar:** The window frame takes the light or dark mode of the palette. On Windows 11, the caption takes `bg` and `text`.
- **Standard controls:** Text fields, check boxes, sliders, menus, and scroll bars use the Fluent theme of WPF in the light or dark mode of the palette. A field of the dock takes `bg`, a `line-hi` border, and an accent border with the focus.
- **Dialogs:** A dialog is a window on `tile-hi` with the content and the buttons at the end. Escape cancels it. The pair request dialog keeps the layout of the Mac sheet.
- **Tray icon:** The Flux mark on the 16-unit grid of the website mark, drawn for the light or dark taskbar, dimmed while no paired computer is connected, with a red dot when an item needs the user. A click opens a panel of 360 px at the bottom right of the screen: the count line, the 2 newest items that need the user as cards, the next items as rows that open their chats, a menu for each online computer, and Open Flux, Settings, and Quit Flux. The right button opens a menu with the same app actions.
- **Notifications:** Windows toasts. The computer name shows as the attribution line. The actions of a category are toast buttons.
- **Keys:** `Ctrl+1` to `Ctrl+3` open Chats, Control, and Computers. `Ctrl+F` goes to the search of Chats. `Esc` and `Alt+Left` go back. `Ctrl+,` opens the settings. In the chat of an agent, `Ctrl+R` reads the output again and `Ctrl+D` shows the changes. Tab reaches each action, and a focused control shows a 2 px accent ring.
- **Differences from macOS:** A tray icon and panel in the place of the menu bar extra. A sidebar of a fixed width. Dialogs in the place of sheets. The Fluent controls of WPF in the place of the AppKit controls. Windows has no photo library, so the tray of a chat shows the newest screenshots in the place of the photos.

## Website

The Flux website uses the system of this file. This section gives only what differs from the apps. All other sections apply where a page can use them.

This section comes from the shipped code in `site/index.html`, `site/style.css`, and `site/main.js`. The site is a static page for GitHub Pages, with no build step. Every page part works without the script.

### Website colors

The site has no live theme. `:root` in `site/style.css` holds the Tokyo Night reference values of the frontmatter as custom properties, with the same role names.

- **Page ground:** `bg` fills the page and the command block.
- **Tiles:** Each part of the page is a `tile` with a 1 px `line` border. A hover on a time link or an end link takes `tile-hi`. The phone frame and the Copied notice take a `line-hi` border.
- **Accent:** Links, the filled button, the colon of a clock, the time in a moment heading, the step numbers, and the bar of the Flux mark. A hover on a link or on the filled button changes it to `cyan`.
- **Cyan:** The shell prompt in a command block, and the second stop of the active border gradient.
- **Red:** Only the marker of a moment that needs the user, in the time list of the rail. The marker is a mix of 45% red into `line` until that moment has the focus. Then it is full red.
- **Green:** Only a Copy button after a copy, with the label "Copied".
- **Faint:** A site-only text color, `--faint` `#8690bb`. It sets the later moments in the rail, the notes in the moments, the captions of the desktop captures, and the foot line of the story. It gives 4.98:1 on `tile` and 5.76:1 on `bg`, so it can carry meaning. The site uses faint, not `dim`, for small text.
- **Selection:** Selected text takes `#33467c` with `text`.
- **Phone glass:** The phone frame fills with `#08080c` around the capture.

### Website type

- **Mona Sans:** It sets what Flux says. The site hosts the variable font itself, in `site/fonts/mona-sans.woff2`, with weights 200 to 900 and widths 75% to 125%.
- **Headings:** Weight 720, width 112%, a line height of 1.06, and a letter spacing of -0.022em. The `h1` has -0.03em. The sizes are `clamp(2.25rem, 1.5rem + 2.4vw, 3.6rem)` for `h1`, `clamp(1.75rem, 1.2rem + 2vw, 2.85rem)` for `h2`, and `clamp(1.3rem, 1.1rem + 0.8vw, 1.7rem)` for `h3`.
- **Body:** Weight 420 at 1.0625rem, with a line height of 1.55. Lines stay at 34em to 40em. The list terms are weight 680 at width 108%. The buttons are weight 640.
- **JetBrains Mono:** It sets the clocks, the times, the prompts, the commands, the step numbers, and the word "flux" of the lockup at weight 700. The site hosts it in `site/fonts/jetbrains-mono.woff2`, with tabular numbers. The Mono Is the Computer Rule applies with Mona Sans in the place of Roboto.
- **Clocks:** Weight 200, a line height of 1, and a letter spacing of -0.04em. The first clock is `clamp(4.75rem, 1.5rem + 7.4vw, 9rem)`. The rail clock is `clamp(3.4rem, 1rem + 4vw, 5.4rem)`, 2.2rem below 1100 px, and 1.8rem below 600 px.

### Website layout

- **Workspace:** The tiles sit in a column of at most 1600 px, with an 8 px gap and a 16 px side inset. Below 600 px, the side inset is 8 px. A new part of the page starts 48 px below the last part.
- **Bar:** A sticky bar of 60 px, or 56 px below 600 px. It shows the lockup, the page links, and a small filled Install button. Its fill is `bg` at 92% with a 10 px blur.
- **Grid:** The first viewport, the theme section, and the trust section split 7 to 5. The first viewport puts the clock, the headline, and the command block on the left, and the phone on the right. A tile of time links runs under the 2 tiles.
- **Story:** A sticky rail with the clock and the time list on the left. The moments in the middle, with a sticky stage on the right that shows the phone. The moments have a gap of 34vh, so 1 moment at a time sits at the middle of the window.
- **From 1099 px down:** The bar hides 3 page links. The rail becomes a thin sticky line with the clock and the label of the moment, and the time list hides.
- **From 899 px down:** Each split becomes 1 column. The stage hides, and each moment shows its own phone. The moments close up to the 8 px gap. The 3 app tiles stack.
- **From 599 px down:** The bar shows only the lockup and its button. The tiles take a 22 px by 18 px inset, and the commands take 0.9rem.

### Website shapes and depth

- **Corners:** 12 px for tiles, buttons, the command block, and the stage. 10 px for page links, chips, desktop captures, and the Copied notice. 8 px for time links and step numbers. 6 px for inline code and the focus ring.
- **Phone frame:** A 7 px inset, a corner of 11% of the phone width, and a screen corner of 9%. Stacked captures in 1 frame cross-fade in 200 ms.
- **Depth:** No shadows. The Flat Tile Rule applies. The bar is the only translucent surface.
- **Focus ring:** 2 px in the accent, with a 3 px offset. In the theme section, it takes the accent of the sample theme.

### Website active border

**The Focus Follows the Middle Rule.** 1 tile at a time carries the active border: the tile at the middle of the window, or else the visible tile nearest to it. A scroll, an anchor jump, or a resize moves it.

- The border is 2 px on the 12 px corner, a 45 degree gradient from `accent` to `cyan`. It fades in over 200 ms.
- Only the tiles with `data-focus` take part. The first tile of the first viewport has the border in the markup, so the page shows 1 active border without the script.
- When a moment takes the focus, the rail clock rolls to its time, the rail shows its label, and the stage phone shows its capture.

### Website components

- **Digit reel clock:** Each digit is a strip of 0 to 9 in a window of 1em. A change rolls the strip in 700 ms with `cubic-bezier(0.16, 1, 0.3, 1)`. The colon is in the accent and blinks to 35% every 2 s. On load, the first clock rolls from 00:00 to 14:07. Without the script, each clock shows its time as text.
- **Flux mark trace:** The mark sits on a 16-unit grid. A square ring of 10 units at 3 units, with a 2-unit stroke in `text`, and a bar of 2 by 14 units at 7 units in the accent. The 4 sides of the ring trace in, 210 ms each, from the top side clockwise, with `cubic-bezier(0.65, 0, 0.35, 1)`. Then the bar drops through in 540 ms with `cubic-bezier(0.22, 1, 0.36, 1)`. The 30 px mark in the bar traces on load. The 120 px mark of the end card traces when 60% of it is in view.
- **Command block:** A `bg` fill, a `line` border, and the 12 px corner. The command is mono at 1rem with a line height of 1.7, after the cyan shell prompt, a `~` and a chevron. The prompt chevron is drawn with a mask, because the font subset has no U+276F. A small tonal Copy button sits at the end. After a copy, the button shows "Copied" in green for 1.8 s, and a notice at the bottom of the window repeats the command. When the browser blocks the copy, the button shows "Copy failed" and the notice tells the user to select the text.
- **Buttons:** The filled kind is `accent` with `on-accent`, and a hover changes it to `cyan`. The tonal kind is `line` with `text`, and a hover changes it to `line-hi`. A button is 48 px high, or 44 px for the small size. The color change takes 200 ms.
- **Theme section:** The tile takes the colors of 5 sample Omarchy themes: Tokyo Night, Catppuccin Latte, Neon, Futurism, and Cotton Candy. A chip picks a theme and has `aria-pressed`. The tile fill is the theme background, and the text is the theme foreground. The borders and the chip fills are mixes of the foreground into the background. The selected chip fills with the theme accent. The active border takes the 2 border colors of the theme. The colors change in 300 ms, and the phone cross-fades to the Inbox in that theme. The sample values are fixed in `site/style.css`. This is the only part of the site with a light theme.
- **Time rail:** A list of the moments with a time and a label. Each item has an 8 px square marker on a 2 px corner. A past moment is `sub`, the moment in focus is `text` with an accent marker, and a later moment is faint.

### Website motion

- The state changes of the site take 200 ms. The theme colors take 300 ms. The clock reels take 700 ms.
- With reduced motion, the site has no animation and no transition. Each clock shows its time at once, and each mark shows drawn.

### Differences from the apps

- No live theme. The site uses the Tokyo Night values, except in the theme section.
- Mona Sans and JetBrains Mono in the place of Roboto and the system mono.
- The active border follows the tile at the middle of the window. The site has no master tile.
- An 8 px gap and a 16 px side inset in the place of the 10 dp gutter.
- The command block fills with `bg`, not `off-tile`.
- A selected theme chip fills with the accent, not `accent-tile`.
- A site-only `--faint` text color, and hover states for a pointer.
- 44 px targets for links and small buttons, and 48 px for buttons.

## Do's and Don'ts

### Do:

- **Do** take every color from a `Tn` role, and check new pairs with the contrast guard in Tokyo Night and Tokyo Night Day.
- **Do** give a chat card that needs the user its whole action in the thread, so that the user answers without a second screen.
- **Do** keep the lines nearest the choices in an agent prompt, so that a one-tap choice never approves a command that the user cannot see.
- **Do** use 8 dp gaps, a 10 dp gutter, and 12 dp corners for tiles.
- **Do** set computer data in mono and Flux text in Roboto.
- **Do** give every control a 48 by 48 dp target, a TalkBack role, and a state.
- **Do** give state in words as well as in color, as the window title does.
- **Do** use 200 ms with the standard easing for shell motion, and no motion when Remove animations is on.
- **Do** take every color in the Apple apps from a `tn` role, as from a `Tn` role on Android.
- **Do** give every control the target of its platform: 48 dp on Android, 44 pt on iOS, and 28 pt for a pointer on macOS.

### Don't:

- **Don't** use red for anything other than "needs you", errors, and the Destructive button kind.
- **Don't** put the active border gradient on any tile other than the pairing guide.
- **Don't** hard-code a color value in a screen.
- **Don't** use `dim` for text that carries meaning.
- **Don't** add shadows to tiles.
- **Don't** build a device list, then a grid of feature cards for each device.
- **Don't** change the layout or behavior of the pairing sheet or the fingerprint approval screen.
- **Don't** change the layout or behavior of the Apple pairing views, the Face ID approval sheet, or the Touch ID approval window.
- **Don't** show any part of a secret clip in the Apple apps. Show "Hidden text" in the body face.
