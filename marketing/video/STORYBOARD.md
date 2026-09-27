# Flux feature videos: herdr and Tailscale

Two videos in one project, rendered with the kit of the earlier Flux video
(`KIT.md`). Each video uses the split frame: the Omarchy desktop in the pane
on the left, Flux for Android on the phone on the right, and the caption
block under the pane. The music is `Terminal Rain`. `audio/music.json` has
the beat grid of each video. Cut on downbeats.

## Shared facts

| Item | Value |
| --- | --- |
| Frame | 1920 x 1080, 60 fps |
| Computer | `omarchy-xps`, laptop |
| Phone | `Pixel 8`, Tailscale name `pixel-8` |
| Home Wi-Fi | computer 192.168.1.20, phone 192.168.1.42 |
| Tailscale | computer 100.101.102.10, phone 100.101.102.103 |
| Bar tooltip | `Pixel 8 · connected`, `Pixel 8 · offline` |

Phone screens are in `assets/phone/`, 1080 x 2400, baked by `tools/bake-phone.sh`
from the emulator captures in `assets/cap/`:

| File | Screen |
| --- | --- |
| `home-nobadge.png` | Device page, Wi-Fi, connected, Agents tile without a count |
| `home.png` | The same page with a red `1` on the Agents tile: 1 blocked agent |
| `agents.png` | Agents list: `NEEDS INPUT` billing, `DONE` web, `WORKING` flux, `IDLE` web |
| `agent-codex.png` | Output of codex in billing: the approval dialog in color, choices `1 Yes`, `2 Yes, and do not ask again for bin/migrate commands`, `3 No, and tell Codex what to do differently (esc)`, key bar `esc ↑ ↓ enter`, field `Write to codex` |
| `ts-home-wifi.png` | Device page on Wi-Fi, `Omarchy · 192.168.1.20` |
| `ts-offline-5g.png` | 5G, `NOT REACHABLE`, `Retry`, the hint `Check that Flux runs on omarchy-xps, and that both are on the same Wi-Fi.` |
| `ts-home-5g.png` | 5G, connected, `Omarchy · 100.101.102.10` |
| `ts-agents-5g.png` | Agents list on 5G |

Tap targets in capture px, from the captures:

| Target | Center |
| --- | --- |
| Agents tile on the device page | 946, 1455 |
| billing card in the agents list | 540, 402. Its box is 26, 276 to 1054, 528 |
| Choice `1 Yes` | 540, 1749. Its box is 28, 1704 to 1052, 1794 |
| The heads-up card | 540, 259 |

Android heads-up: `engine/ui/headsup.js`. Put it in `phone.overlay`.

Text rules: ASD-STE100 as in `KIT.md`. No em dashes, semicolons,
parentheses, exclamation marks, or hype. Keep each caption title to 8 words
or fewer. App strings must match the captures and the source exactly.

The desktop terminal shows the pane of the agent, not the herdr interface.
Do not draw herdr menus, tabs, or status lines. The agent output text comes
from `DebugDemo.kt` in the Flux repository:

```text
● I added the migration in db/migrate/0042_add_invoice_status.sql.

● Bash(bin/migrate --dry-run)
  ⎿  1 migration to apply: 0042_add_invoice_status

──────────────────────────────────────────────────────────────────────── (blue)
 Bash command                         (bold blue)

   bin/migrate --apply
   Apply the pending migration        (dim)

 Do you want to proceed?
 ❯ 1. Yes                             (blue)
   2. Yes, and do not ask again for bin/migrate commands
   3. No, and tell Codex what to do differently (esc)
```

Colors: the first bullet is rgb(215,119,87), the second bullet green, `⎿` dim,
`0042_add_invoice_status` cyan. After the answer, the dialog closes and the
agent prints:

```text
● Bash(bin/migrate --apply)
  ⎿  Applied 0042_add_invoice_status

● The migration is applied. The invoices table has a status column now.
```

## Video 1: herdr agents on your phone

`timeline-herdr.js`, 3133 frames, 52.2 s. Track start 0 s.
Downbeats: 91, 293, 496, 699, 902, 1105, 1307, 1510, 1713, 1916, 2119, 2322,
2524, 2727, 2930. Break 1440 to 1662. Hit 1713.

| Scene | Frames | Content |
| --- | --- | --- |
| `h01-work` | 0 to 496 | The agent works |
| `h02-ping` | 496 to 902 | The agent blocks, the phone gets a notification |
| `h03-list` | 902 to 1307 | The agents list |
| `h04-read` | 1307 to 1713 | The output with the dialog, tension in the break |
| `h05-answer` | 1713 to 2322 | The tap on the hit, the agent continues and finishes |
| `h06-setup` | 2322 to 2727 | Turn on replies |
| `h07-end` | 2727 to 3133 | End card |

### h01-work, 0 to 496

- Desktop: one Ghostty window that fills the tiled area. It shows the codex
  agent. The first 4 lines of the output stream in from frame 30 to 300, one
  line every 12 to 20 frames, as a working agent prints them.
- From frame 330, the dialog block draws line by line, 3 frames per line.
  The pane camera pushes from WIDE toward the dialog, ending near z 1.35.
- Phone: `home-nobadge.png`.
- Caption at 91: kicker `herdr agents`, title `Your coding agents work in herdr.`,
  sub at 130: `Flux shows them on your phone.`

### h02-ping, 496 to 902

- The dialog stays on the desktop. At 500 the phone vibrates for 60 frames,
  and the heads-up slides down: title `codex in billing needs input`,
  text `Run the database migration`. The phone screen changes to `home.png`
  at the same frame, so the Agents count shows.
- The flux arc runs from the dialog on the desktop to the heads-up at 500.
- The heads-up slides up at 640.
- A tap on the Agents tile at 800. The screen cuts to `agents.png` at 812.
- Caption at 514: kicker `Notifications`, title `Know when an agent needs you.`,
  sub: `The phone gets a notification when an agent waits for input.`

### h03-list, 902 to 1307

- Phone: `agents.png`. The billing card glows once in red at 920, then
  holds.
- Desktop: the camera eases back toward WIDE, so the agent and the list read
  as one system.
- A tap on the billing card at 1250. The screen cuts to `agent-codex.png`
  at 1262.
- Caption at 920: kicker `Agents`, title `See every agent in one list.`,
  sub: `Blocked agents come first, then done, working, and idle agents.`

### h04-read, 1307 to 1713

- Phone: `agent-codex.png`. The phone scales up to about 1.4 times and moves
  toward the pane center over 40 frames from 1307, so the dialog is
  readable. The desktop pane dims to 40 percent under it. Scale back before
  1700.
- In the break, 1440 to 1662, the motion slows and holds. A soft pulse
  outlines the `1 Yes` button from 1560.
- Caption at 1325: kicker `Output`, title `Read the output in color.`,
  sub: `The phone shows the same dialog as the terminal.`

### h05-answer, 1713 to 2322

- 1713, on the hit: a tap on `1 Yes`, rings at the button, and the arc from
  the phone to the dialog on the desktop.
- 1725: the dialog closes on the desktop, and the new lines print from 1740
  to 1900.
- The camera holds on the terminal.
- 2119: the second heads-up on the phone: title `codex in billing finished`,
  text `Run the database migration`. It slides up at 2260.
- Caption at 1725: kicker `Replies`, title `Answer from your phone.`,
  sub: `A tap sends the number of the choice to the agent.`

### h06-setup, 2322 to 2727

- Desktop: a terminal types these lines, each after the previous one ends:

  ```text
  ~ ❯ echo 'herdr_control = true' >> ~/.config/flux/config.toml
  ~ ❯ systemctl --user reload fluxd
  ```

- Phone: `agent-codex.png`, at rest.
- Caption at 2340: kicker `Setup`, title `Turn on replies with one line.`,
  sub: `Replies are off by default, because an agent can run commands.`

### h07-end, 2727 to 3133

The end card of the earlier video, `ref/s17-end.js`, adapted:

- The Flux mark and `flux`.
- Title: `herdr agents on your phone.`
- Sub: `Install Flux on both sides.`
- Left box `ON OMARCHY`: `yay -S omarchy-flux` and `flux setup`.
- Right box `ON ANDROID`: `Get the APK from the Flux GitHub release.`
- The music fades out over the last 3 s.

## Video 2: Flux through Tailscale

`timeline-tailscale.js`, 3042 frames, 50.7 s. Track start 55.5935 s.
Downbeats: 0, 203, 406, 608, 811, 1014, 1217, 1420, 1623, 1825, 2028, 2231,
2434, 2637, 2839, 3042. Break 1344 to 1542. Hit 1623.

| Scene | Frames | Content |
| --- | --- | --- |
| `t01-home` | 0 to 406 | Flux at home on Wi-Fi |
| `t02-add` | 406 to 1014 | Add the Tailscale name, check with doctor |
| `t03-leave` | 1014 to 1623 | The phone leaves the Wi-Fi, the link drops |
| `t04-back` | 1623 to 2231 | The link comes back through Tailscale |
| `t05-work` | 2231 to 2637 | Features work away from home |
| `t06-end` | 2637 to 3042 | End card |

The desktop keeps one Ghostty window through `t02` to `t05`, so the
terminal lines continue across the cuts.

### t01-home, 0 to 406

- Phone: `ts-home-wifi.png`.
- Desktop: the bar shows Flux online. At 60 the pointer hovers the Flux bar
  widget, and the tooltip `Pixel 8 · connected` shows from 70 to 330.
- A thin dashed line labeled `Wi-Fi` joins the pane and the phone, in the
  gap between them, from 40.
- Caption at 18: kicker `Tailscale`, title `Use Flux away from home.`,
  sub at 60: `Flux reaches your phone through Tailscale.`

### t02-add, 406 to 1014

- Desktop: the terminal types, and prints output after each command:

  ```text
  ~ ❯ tailscale status
  100.101.102.10   omarchy-xps  you@  linux    -
  100.101.102.103  pixel-8      you@  android  -
  ~ ❯ flux --device "Pixel 8" addresses add pixel-8
  Added pixel-8. Addresses of Pixel 8: pixel-8
  ```

  From 811:

  ```text
  ~ ❯ flux doctor
  ✓ fluxd is running
  ✓ fluxd listens on TCP 1716
  ✓ pixel-8 resolves, so fluxd can reach Pixel 8 through it
  ```

  Highlight `pixel-8` in accent blue in the add command and in the doctor
  line. The camera frames the terminal at about z 1.3.
- Phone: `ts-home-wifi.png`.
- Caption at 424: kicker `Setup`, title `Add the Tailscale name of your phone.`,
  sub: `Pair on your local network first. Then add the name once.`

### t03-leave, 1014 to 1623

- 1014 to 1340: the terminal runs `journalctl --user -u fluxd -f` and waits.
  The dashed `Wi-Fi` line still joins the pane and the phone.
- 1344, the start of the break: the phone status bar loses Wi-Fi. Cut the
  phone to `ts-offline-5g.png`. The `Wi-Fi` line breaks in the middle and
  fades.
- 1380: the journal prints
  `link down: Pixel 8: read tcp 192.168.1.20:45098->192.168.1.42:1716: connection timed out`.
  The bar widget goes offline, and the tooltip reads `Pixel 8 · offline`.
- The break holds still until 1600.
- Caption at 1032: kicker `Away`, title `Your phone leaves the Wi-Fi.`,
  sub at 1380: `fluxd sees that the old link is down.`

### t04-back, 1623 to 2231

- 1623, on the hit: the journal prints
  `link up: Pixel 8 (100.101.102.103) paired=true`. The phone cuts to
  `ts-home-5g.png`. The bar widget comes online, and the tooltip reads
  `Pixel 8 · connected`. A new line labeled `Tailscale` joins the pane and
  the phone, solid accent blue. Rings at the phone status card.
- 1900: the terminal runs `flux notify "Build done" "412 files, 2.1 GB"`.
  At 1915 the phone shows a heads-up: title `Build done`, text
  `412 files, 2.1 GB`. The arc runs from the terminal to the phone. It slides
  up at 2150.
- Caption at 1635: kicker `Tailscale`, title `Flux connects again through Tailscale.`,
  sub: `fluxd dials the extra address while the phone is offline.`

### t05-work, 2231 to 2637

- Phone: `ts-agents-5g.png`. A tap on the Agents tile is not needed. Cut on
  2231.
- Desktop: the terminal runs `flux status` and prints
  `  Pixel 8                phone   connected  82% +  100.101.102.103  paired`.
- Caption at 2249: kicker `Everywhere`, title `Every feature uses the same link.`,
  sub: `Files, clipboard, notifications, and agents work through Tailscale.`

### t06-end, 2637 to 3042

The end card of the earlier video, adapted:

- The Flux mark and `flux`.
- Title: `Flux through Tailscale.`
- Sub: `Add the Tailscale name of your phone once.`
- One box, centered: `flux --device "Pixel 8" addresses add pixel-8`.
- Under it: `Read docs/tailscale.md for the steps.`
- The music fades out over the last 3 s.
