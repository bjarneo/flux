# herdr agents

[Documentation index](README.md)

Flux for Android and Flux for macOS show the coding agents that [herdr](https://herdr.dev) runs on your Omarchy computer.
You can see the status of each agent, read its recent output in color, and get a notification when an agent needs input or finishes.
When you turn on control, you can also answer an agent with taps, send it text, start new agents, and close agents.
When you also turn on terminals, Flux for Android opens herdr terminals and types commands in them.
With control on, Flux for Android can also show the live terminal of an agent, and you can scroll and tap in it.

The phone uses the Flux link that it already has.
It needs no new port, no firewall rule, and no new pairing.
This page describes the phone. A Mac works the same way, and [Use a Mac](#use-a-mac) describes where it differs.
An iPhone with [Flux for iOS](ios.md) works like the Android phone. It dictates in the languages of the iPhone, and it gets agent notifications only while Flux runs.
Flux for iOS and Flux for macOS do not show the live terminal.

```text
herdr server ── Unix socket ── fluxd ── Flux TLS link ── Flux for Android
```

`fluxd` is the only herdr client.
The phone never connects to the herdr socket.

## Requirements

- herdr with API protocol 22 or newer. herdr 0.9.1 uses protocol 22.
- herdr and `fluxd` run as the same desktop user. `fluxd` refuses a herdr socket that belongs to another user.
- A `fluxd` and a Flux for Android or Flux for macOS that both include this feature.
- For the [live terminal on Android](#live-terminal-on-android): herdr 0.9.3 or newer, `herdr_control = true`, and a screen lock on the phone. The herdr server and the `herdr` CLI in the `PATH` of `fluxd.service` both need herdr 0.9.3 or newer.

To check the desktop side, run:

```sh
flux-cli doctor
```

When herdr runs and `herdr_control = true`, `flux-cli doctor` prints these lines:

```text
✓ herdr 0.9.3 runs, so the phone can show its agents
✓ herdr 0.9.3 runs, and fluxd runs /usr/bin/herdr 0.9.3, so the phone can show the live terminal
```

With herdr 0.9.1 or 0.9.2, the phone shows the agents, and the second line names the problem and the fix.

The live terminal is optional.
With `herdr_control = false`, the second line is a note and not a problem:

```text
- The live terminal on the phone needs herdr_control = true in config.toml
```

## See your agents

The agent screen opens on the **Output** view on each app.
It also has a **Changes** view for Git diffs and review feedback.
See [Agent diff review](workflows.md#agent-diff-review).

1. Start herdr on the computer.
2. Open Flux for Android. An agent that waits for input shows first in the **Inbox**, with its question and its choices.
3. To see all agents, open **Control** and select **Agents and terminals**.
4. Select an agent to read its recent output.

The list puts blocked agents first, then done, working, idle, and unknown agents.
A blocked agent waits for an approval or for the answer to a question.
Idle and done agents are ready for new input.
The **Agents and terminals** tile shows the number of blocked agents.

On Android, the **Live** key in the top bar shows the live terminal of the agent in the place of the output.
See [Live terminal on Android](#live-terminal-on-android).

The output screen of the phone shows up to 1000 lines of recent output.
The screen part of the output has the colors and styles of the terminal.
The older lines above it are plain text.
It reads the output again every 5 seconds while the agent works, and after each status change.
A timed read waits while the last read still loads, so the reads do not pile up on a slow link.
A new status reads at once.
Select refresh to read it at once.

The screen opens at the newest lines.
When you scroll up to read older lines, the screen stays there when new output comes.
To go back to the newest lines, select the arrow at the bottom of the output.

Many agents, such as Claude Code, draw in the alternate screen of the terminal.
herdr gets the older lines of such an agent only while the agent is idle, and only as plain text.
While the agent works, the phone shows the older lines from the last idle read above the current screen.
When the two parts do not meet, a dim line says that more lines show when the agent stops.
The phone reads all lines again when the agent stops.
herdr keeps only the recent part of the terminal for some agents, so the screen can show fewer lines.

While a phone controls the agent in Live, `fluxd` does not read the older lines, because herdr scrolls the terminal to read them.
Each device then shows the older lines of the last read above the current screen.
When the two parts do not meet, a dim line says that older lines update when the phone releases this agent.
When `fluxd` has no older lines of the agent yet, the dim line shows above the current screen.
The screen part then has the size of the phone grid.

The phone fits the output to its narrow screen.
Claude Code, Codex, opencode, and other agents draw for the full width of the terminal, so a line from the computer is often wider than the screen:

- The phone joins the rows that the agent wrapped at the width of the terminal, and it wraps the text again at the width of the screen. Without this step, each wrapped row leaves a short piece on the screen. A list item, a rule, and a row of a box stay on their own lines. The phone finds the width of the terminal from a rule or from a row with a background, so it joins no rows in output that has neither.
- A long line wraps, and its wrapped rows start under its text, after the panel bar or the list marker. A list marker is a symbol and a blank at the start of the line, for example `●`, `❯`, `›`, `⎿`, or `-`.
- A rule fills the width of the screen. A rule with a title, for example the session name above the prompt of Claude Code, keeps the title and gets shorter.
- A hint at the right edge of the terminal, for example `new task? /clear to save 120k tokens` of Claude Code, moves to the right edge of the screen.
- A box that is wider than the screen loses its right side, so its rows wrap under the left side. A table keeps all its sides.
- The phone removes the margin that all lines share, extra empty rows, scroll bars, and the half-block edges of boxes.
- A panel, for example a message, a tool call, or a diff line in opencode, fills the width of the screen.
- The phone removes the sidebar that opencode shows in a wide terminal, because its rows share the lines of the conversation. The status line at the bottom still shows the tokens and the cost.
- The phone also removes the expanded vertical session tabs of OpenCode V2 when their
  titles and **New session** row are visible. This keeps the conversation and
  prompt at the left without changing the tab layout on the computer. Horizontal tabs
  stay in the output. A compact or partially visible vertical rail is not detected yet.
- A centered drawing, for example the opencode logo, moves to the left when that makes it fit.
- When the agent colors suit a dark background and the phone uses the light theme, the phone inverts the lightness of these colors, so the text stays readable. It does the same for colors that suit a light background in the dark theme.
- Many phone fonts do not have the symbols `⏵`, `⏴`, `⏶`, `⏷`, and `⏺`. The phone shows `▸`, `◂`, `▴`, `▾`, and `●` in their place. Flux for Android also draws the rule characters `─`, `━`, and `═` itself, because its mono font has no glyphs for them.

A wide terminal makes opencode show a diff in 2 columns, for example in a permission dialog.
The 2 columns do not fit the screen of a phone.
To show each diff in 1 column, set `diff_style` in `~/.config/opencode/tui.json` on the computer:

```json
{
  "$schema": "https://opencode.ai/tui.json",
  "diff_style": "stacked"
}
```

### Live terminal on Android

Flux for Android can show the live terminal of an agent in the place of the output.
The phone then controls the pane on the computer.
The **Output** view stays the default on each app.
Flux for iOS and Flux for macOS show the output of an agent and do not have Live.

Live needs these items:

- herdr 0.9.3 or newer for the herdr server.
- herdr 0.9.3 or newer for the `herdr` CLI in the `PATH` of `fluxd.service`. `fluxd` runs this CLI for each live terminal.
- `herdr_control = true`. See [Answer an agent](#answer-an-agent).
- A `fluxd` and a Flux for Android that include Live.
- A screen lock on the phone.

The **Live** key shows in the top bar of an agent screen when the computer is online, the agent runs, and the computer offers control.
It does not show in the **Changes** view.
With an older `fluxd`, an older herdr, or `herdr_control = false`, the key does not show, and the agent screen shows the output as before.
To find the cause, run `flux-cli doctor` on the computer.
It checks `herdr_control`, the herdr server, and the herdr CLI of `fluxd`. See [Requirements](#requirements) for its herdr lines.

To show the live terminal:

1. Open the screen of an agent.
2. Select **Live** in the top bar.
3. Unlock the phone with the fingerprint or the screen lock in the **Open the terminal** prompt.

A valid unlock from the last 5 minutes opens Live with no prompt.
The replies to agents use the same unlock.

The live terminal then takes the place of the output.
With a computer that supports live input, a key bar and a keyboard key replace the composer.
The keyboard types directly in the program; Return sends Enter, and a tap does not open it.
Input waits for the first frame and the same five-minute unlock, and reconnects replay no input.
Output and Changes keep the choices, composer, Send, and dictation as before.
An older computer keeps those controls in Live too.
**Refresh** does not show while Live is on.
The phone then reads the output only when Live opens and when the status changes, so the choice tiles stay current.
Until the first full screen draws, a cover shows **Opening the terminal…**.
The cover shows **Reconnecting…** while Live opens the stream again.
The terminal uses the colors of the computer theme for the default colors, and it keeps the colors that the agent sets.

Live changes the pane on the computer:

- herdr resizes the pane to the grid of the phone, about 60 columns. The agent draws its screen for that grid.
- When the width of the view changes, for example after a rotation, the phone resizes the pane again and keeps control.
- While the keyboard shows, the pane keeps its size, and the view shows the bottom rows.
- When the phone releases control, herdr gives the pane the size of the desktop again when the desktop has an attached herdr client. Without such a client, the next herdr client that attaches sets the size.
- One device controls a pane at a time. Another device cannot take control until the first device releases it.

The gestures on the live terminal are:

- One finger scrolls the agent on the computer. After a quick swipe, the scroll continues for a short time. A new touch stops it.
- A short tap clicks the left mouse button at the cell under the finger, for example on a button of the agent. herdr sends the click only to an agent that uses the mouse. A drag, a long press, and a touch that stops a scroll do not click.
- Two fingers zoom and pan the view on the phone. They send nothing to the computer.

The live terminal takes no keys and no text.
To type, use the text field and the key bar under the terminal.

Live releases control when you select **Live** again, select **Changes**, leave the agent screen, or put the app in the background.
When the app comes back while the unlock is valid, Live takes control again.
The unlock stays valid for 5 minutes, and Live does not extend it.
When the unlock ends, Live ends, also while the terminal shows.
While the computer is not reachable, the agent screen says so, and the **Live** key stays on.
When the computer connects again while the unlock is valid, Live opens again.
When the link drops during the unlock prompt, the prompt shows again after the computer connects again.

Live also ends by itself in these cases:

- You cancel the unlock, or the phone has no screen lock.
- The agent ends, or herdr closes the pane. The phone ends Live when the agent list of the computer no longer has the agent. A new agent in the same pane does not open Live. To open it, select **Live** again.
- `fluxd` stops the stream, for example after a change of `herdr_control` or when herdr stops.
- The computer refuses the open. The line above the output shows the error of `fluxd`. When `fluxd` marks the error as temporary, Live first tries again, as for a failed stream.
- The stream fails, or the computer does not answer. Live first tries again 4 times, after 1, 2, 4, and 8 seconds. After a stream shows for 30 seconds, the count of tries starts again.
- Android stops the page that draws the terminal, for example to free memory.

When Live ends by itself, a line above the output tells why, for example `The unlock ended. Tap Live to open the terminal again.`
When the agent ends or herdr closes the pane, the line shows above **The agent is gone**.
Without `herdr_terminals`, the phone does not get the list of panes, so the line for a closed pane also says that the agent ended.
TalkBack reads this line.
The next tap on **Live** removes it.

If TalkBack is on when Live opens, TalkBack can read the rows of the terminal.
TalkBack does not read each new frame aloud.
To read or copy the text of the agent, use the **Output** view.

Live shows the cells of the terminal with their colors and styles.
It does not show images that a program draws in the terminal.
Only an agent screen has Live. The screen of a terminal does not have it.

## Notifications

The phone posts a notification when an agent changes to blocked.
It also posts a notification when an agent changes from working to done or idle.
A tap opens the output of that agent.

The phone does not post notifications for the first agent list after it connects.
It waits 2 seconds before a finished notification, because the status can change between tool calls.
When the agent works again, the phone removes its notification.

To turn off a notification type, use the **Agent needs input** or **Agent finished** switch in **Computers > Sync** on the phone.
The switches apply to all computers.
Android also lists the two types as the **Agents that need input** and **Agents that finish** channels.

## Answer an agent

Replies are off by default, because an agent runs commands on the computer.
With replies on, a paired device can make an agent run any command as your user, also when `herdr_terminals` is `false`.
For example, Claude Code runs a prompt that starts with `!` as a shell command, and a reply can approve each command that an agent asks to run.
The setting applies to every paired device.
Turn it on only when you trust each paired device.
See [Access and privacy](#access-and-privacy).

To let the phone send keys and text to the agents, set this key in `~/.config/flux/config.toml`:

```toml
herdr_control = true
```

Reload the daemon:

```sh
systemctl --user reload fluxd
```

The output screen then shows the reply controls:

- When the agent is blocked, the phone shows the numbered choices of the dialog as buttons. A tap sends the number of the choice.
- The key bar sends Esc, Tab, Up, Down, and Enter.
- The text field sends a prompt to the agent. The clear key empties the field. The expand key opens a large editor with **Send** for a long prompt.
- When the agent waits for a choice, `fluxd` refuses the text with the message `The agent waits for a choice. Pick a choice first.` A digit or Enter in the text can select a choice of the dialog, for example an approval. Pick a choice with the buttons or the key bar first.
- After this refusal, the message shows **Send as answer** next to it while the field holds the same text. Select it when the agent asks a question that needs free text, for example an answer that is not in the choices. The app sends the same text again with `"answer": true`. `fluxd` checks that the agent still waits, types the text on one line, and presses Enter. The iPhone and the Mac show the same action.

With herdr 0.9.3 or newer, the same setting also turns on the **Live** key of Flux for Android.
See [Live terminal on Android](#live-terminal-on-android).

Before the first reply, the phone asks for its fingerprint or screen lock.
The unlock stays valid for 5 minutes.

`fluxd` accepts these keys only: `enter`, `esc`, `tab`, `shift+tab`, `up`, `down`, `left`, `right`, `backspace`, `space`, `0` to `9`, `y`, and `n`.
It does not accept `ctrl+c`, because that key can end the agent.
A prompt can have up to 16 KB of text.
`fluxd` removes control characters from a prompt, except line breaks and tabs.

## Start an agent

With `herdr_control = true`, the phone can start a coding agent on the computer.

1. Open **Agents**.
2. Select the add button in the top bar.
3. Under **Run**, select the agent, for example `claude` or `codex`.
4. Under **Folder**, select a folder. To find a folder, type or speak a part of its name. To use another folder, type its path, for example `~/Code/app`. The folder must exist on the computer.
5. When the folder has a herdr workspace, select **New tab in** that workspace or **New workspace**. A folder without a workspace opens in a new workspace.
6. Select **Start**.

The folder list shows your home folder and the folder of each herdr workspace, in the order of the herdr sidebar.
Each folder shows the number of agents in its workspace.
The phone keeps the last agent and folder of each computer for the next start.

Before the first start, the phone asks for its fingerprint or screen lock.
herdr opens a shell in the folder, runs the agent command there, and waits until it finds the agent.
The start can take 30 seconds.
The phone then opens the screen of the new agent.

The list shows only the agents that can run on the computer.
`fluxd` looks for the command of each agent kind in its `PATH`.
A mise shim or an Omarchy launcher counts only when `mise which` finds the tool active in your home folder.
`fluxd` never runs an agent command to check it, because an Omarchy launcher installs its tool on the first run.
`fluxd` checks the agents again each minute, so a new install shows within a minute.
The check runs in the background, so the agent list does not wait for it.
One start from each device runs at a time. A second start from the same device gets an error until the first one ends.
When the agent does not start, `fluxd` closes the new pane and the phone shows the last line of the shell, for example `command not found`.

A new agent in a new folder can ask if you trust the folder.
The agent is then blocked, and the phone shows the choices.

## Close an agent

With `herdr_control = true`, select **Close** on the screen of an agent, then confirm.
herdr closes the pane, and the agent in it stops.
When the pane is the last one of its tab, herdr also closes the tab.
When the tab is the last one of its workspace, herdr also closes the workspace.

## Use terminals

Terminals let the phone type commands in each herdr pane that has no agent, so they are off by default.
`herdr_control` alone already lets an agent run commands for the phone.
To let the phone open herdr terminals and type in them, set these keys in `~/.config/flux/config.toml`:

```toml
herdr_control = true
herdr_terminals = true
```

Reload the daemon:

```sh
systemctl --user reload fluxd
```

The **Agents** screen then lists each herdr pane that has no agent under **Terminals**.
The list includes the panes that you opened on the computer, for example a `sudo -i` shell or an SSH session.
The phone can read and type in each of them.
Select a terminal to see its output and to type in it:

- Type a command in the field, then select **Run**. The phone types the command and presses Enter.
- The clear key empties the field. The expand key opens a large editor with **Run** for a long command.
- To speak a command, select the mic key next to **Run**. The command goes in at the cursor without the capital and the period of a sentence. Read it, then select **Run**.
- The key bar sends Esc, Tab, Ctrl-C, Ctrl-D, Up, Down, and Enter.
- The screen reads the output again every 3 seconds. A read waits while the last read still loads.
- To close the terminal, select **Close**, then confirm.

To open a new terminal, select the add button on the **Agents** screen, then select **terminal** under **Run**.

Before the first input, the phone asks for its fingerprint or screen lock.
The unlock stays valid for 5 minutes.

`fluxd` accepts these keys for a terminal: `enter`, `esc`, `tab`, `shift+tab`, `up`, `down`, `left`, `right`, `backspace`, `space`, and `ctrl+a` to `ctrl+z`.
A command can have up to 16 KB of text.
`fluxd` removes control characters from a command and changes line breaks and tabs to spaces.

## Dictate a reply

To talk to an agent instead of typing, use the mic key next to **Send**.
The phone changes your speech to text in the reply field.
The audio does not go to the computer.

- To start, tap the mic key. To stop, tap the red stop key in the panel.
- To talk only while you hold the key, press and hold it. The dictation stops when you release it.
- To drop the dictation, select the close button in the panel.

While the phone listens, a panel takes the full width of the reply bar.
It shows the language, the time, a live voice wave, and the words so far.
The final words are bright. The words that the recognizer still hears are dim and can change.
A pause does not end the dictation.
The dictation ends when you stop it, after 20 seconds with no speech, or after 5 minutes.
When the app goes to the background, the dictation ends and keeps its words.

The text goes in at the cursor of the field and stays there.
Read it, then select **Send**.
The send asks for the phone lock, as a typed prompt does.

Flux uses the on-device speech recognizer of Android when the phone has one.
The recognizer tries the phone languages in the order of the Android language settings and uses the first one that it has a model for.
For example, the Google on-device recognizer has no Norwegian model, so a phone with Norwegian and then English uses English.
The panel header shows that language.
The recognizer also gets the agent, project, and workspace names, so that it can spell them.
When the phone has no on-device recognizer, Flux uses the default recognizer and asks it to stay offline.
That recognizer can use a network service when it has no offline model for the phone language.

### Choose or download a language

To use another language, select the language button in the panel header.
The dictation stops, and its words stay in the field.
The language picker opens:

- **Automatic** uses the phone languages in order, as described above.
- **On this phone** lists the languages that have a model. Select one to use it. The next dictation starts at once.
- **Download** lists the languages that the recognizer can download. Select one to download it.

Android asks you to confirm each download and shows its size.
The picker shows the progress, and it selects the language when the download is done.
Android downloads each model from Google once.
Dictation then runs on the phone, and the audio stays on the phone.
Flux keeps the language that you select for the next dictations.

Android 13 and later can list and download models.
Android 14 and later also report the progress of a download.
On Android 12 and earlier, the picker lists only the phone languages.

The first dictation asks for the microphone permission.
The mic key does not show when the phone has no speech recognizer.

## Use a Mac

Flux for macOS shows the same agents and sends the same replies as the phone.
It shows up to 1000 lines of output.
It does not start agents, close them, open terminals, or show the live terminal.

- **Control** has the **Agents and terminals** tool. Its line counts the agents and the terminals. Its badge shows the number of blocked agents.
- The Inbox shows each agent that waits for input, works, or is done. See [Inbox and navigation](macos.md#inbox-and-navigation).
- **Agents and terminals** opens a window with the agent list on the left and the output of the selected agent on the right. When more than 1 computer has agents, Flux asks which one.
- **Reply** and **Open** on the master tile of the Inbox open the agent in that window. The menu of each computer in the menu bar panel has **Agents…** too.
- The output uses the colors of Tokyo Night in dark mode and Tokyo Night Day in light mode.
- The Mac fits the output to the width of the window, as the phone does. See [See your agents](#see-your-agents).
- When you scroll up to read older lines, the output stays there when new output comes. To go back to the newest lines, select the arrow at the bottom of the output.
- Each output line selects its own text. To copy all the output, select the copy button above the output.
- Press Command-R to read the output again.
- Return sends the text. Shift-Return adds a line break.
- Before the first reply, the Mac asks for Touch ID or the Mac password. The unlock stays valid for 5 minutes, until the Mac sleeps or locks.
- The **Agent needs input** and **Agent finished** switches are in **Settings > Features**. They apply to all computers. A click on a notification opens the agent in the agents window.

### Dictate on a Mac

The mic key works as on the phone: click to start and stop, press and hold to talk, and select the close button to drop the dictation.
The dictation ends when you stop it, after 20 seconds with no speech, or after 5 minutes.
It does not end when Flux goes to the background.

The Mac uses the Speech framework of macOS.
When the Mac has the speech model of a language, the recognizer runs on the Mac and the audio stays on the Mac.
For other languages, Apple transcribes the speech, so the audio goes to Apple.
The language button in the panel shows a laptop for a language on the Mac and a cloud for a language that Apple transcribes.
The audio never goes to the computer.

- **Automatic** tries the languages in **System Settings > General > Language & Region** in order. It uses the first one that has a speech model on the Mac. When none has a model, it uses the first one that Apple transcribes.
- A Mac language often has the region of the Mac, for example English (Norway). Flux then uses another region of the same language. It prefers the language that the speech recognizer of macOS uses by default.
- To choose a language, select the language button in the panel. The picker lists **On this Mac** and **Transcribed by Apple**. Flux keeps the language for the next dictations.

macOS downloads the speech models itself, so the picker has no download list.
To get the model of a language, add the language under **Dictation** in **System Settings > Keyboard**, then open the picker again.

The first dictation asks for Speech Recognition and the microphone.
The mic key does not show when the Mac has no speech recognizer.

## Turn the feature off

To stop sending agents to the phone, set this key in `~/.config/flux/config.toml`:

```toml
herdr = false
```

Reload the daemon:

```sh
systemctl --user reload fluxd
```

The phone then shows that the feature is off on the computer.

## Use another herdr session

`fluxd` follows the default herdr session.
It uses the first path that applies:

1. `$HERDR_SOCKET_PATH`
2. `$XDG_CONFIG_HOME/herdr/herdr.sock`
3. `~/.config/herdr/herdr.sock`

To list the socket of each session, run:

```sh
herdr session list --json
```

To follow a named session, set the variable for the service:

```sh
systemctl --user edit fluxd
```

Add these lines, then restart the service:

```ini
[Service]
Environment=HERDR_SOCKET_PATH=SOCKET_PATH
```

Replace `SOCKET_PATH` with the `socket_path` value of the session from `herdr session list --json`.

```sh
systemctl --user restart fluxd
```

## Access and privacy

The phone can read the agent list and the recent output of an agent pane.
`fluxd` also lets a paired device watch the live terminal of an agent pane, with no input. Flux for Android does not use this.
With `herdr_control = true`, it can also send the keys in the list above and prompts to an agent, start agents, and close agent panes.
It can also control the live terminal of an agent pane: click at any cell, scroll, and resize the pane to its grid.
A click can press each button of the agent, for example an approval.
An agent runs commands, so a reply has the same power as a prompt that you type on the computer.
`herdr_control` alone lets the phone run any command as your user, also when `herdr_terminals` is `false`.
For example, the phone can start Claude Code in any folder and send a prompt that starts with `!`, which Claude Code runs as a shell command.
`fluxd` reads and sends only to panes that hold an agent in the last agent list.
herdr also checks that an agent is in the pane before it sends a key or a prompt.
`fluxd` ends a live terminal when the agent leaves its pane.
`fluxd` finds this in the agent list of herdr, so the stream can run for a short time after the agent ends.

With `herdr_terminals = true` and `herdr_control = true`, the phone can also read, type in, open, and close each herdr pane that has no agent.
These panes include the panes that you opened on the computer, for example a `sudo -i` shell or an SSH session.
The phone can then run any command in them, also as root or on the remote host.
A device needs `herdr_terminals` to watch or control the live terminal of a pane without an agent.
Without this setting, `fluxd` answers the open as for a pane that it does not know.

`herdr_control` and `herdr_terminals` apply to every paired device, for example a second phone, a tablet, or a Mac.
A [device restriction](workflows.md#per-device-access) can turn them off for one device.
The app asks you to unlock it before the first reply and before Live, but `fluxd` cannot check that the app did.
Turn the settings on only when you trust each paired device.
Unpair the devices that you do not use.

`fluxd` logs each reply with the device name, the pane, and the keys.
For a prompt and a terminal command, it logs the number of characters, not the text.
It also logs each new agent, new terminal, and closed pane.
For a live terminal, it logs the start, each press of a mouse button with its cell, and the end.
It does not log the release of a button, a drag, a move, a scroll, or a resize.
When the input to a live terminal fails, it logs only the first error of the stream.

Terminal output can contain secrets.
The output and the live terminal go only to paired devices over the Flux TLS link.
`fluxd` does not write the output or the frames of a live terminal to its log.

## How it works

`fluxd` subscribes to herdr events for new agents, closed panes, moved panes, and workspace changes.
It also subscribes to the status of each agent pane, because herdr needs a pane ID for that event.
After each event, `fluxd` reads the session snapshot and sends the agent list when it changed.
It also reads the snapshot every 10 seconds, which finds title changes.

When herdr stops, `fluxd` tries to connect every 5 seconds.
When the phone opens the agent list, `fluxd` tries at once.

`fluxd` limits the work that one device can start:

- One read of each pane runs at a time for each device. A read that comes during the herdr calls of that read gets the same answer. A read that comes while `fluxd` sends the answer gets a new read after it.
- When the agent status changes or a reply goes to the pane during the herdr calls, the answer can be old. The reads that came during the herdr calls then get a new read.
- A read that comes during the herdr calls with another line count or format also gets a new read. That read uses the line count and the format of the newest read.
- A read, a reply, or a close for a pane that `fluxd` does not know gets its error at once.
- Up to 4 keys, prompt, input, and close requests run at a time for each device. A 5th request gets the error `fluxd is busy with earlier replies from this device. Try again.`
- `fluxd` keeps the plain history of an idle agent for 3 seconds, so a new read in that time does not make herdr scroll the agent again. A new status of the agent, a reply to it, and a new agent in the pane end this time.
- One start of an agent or a terminal runs at a time for each device.
- One open of a live terminal runs at a time for each device. A second open gets the error `fluxd already opens a terminal for this device. Try again.` and `"retry": true`.
- Each device has 1 live terminal at a time, and each pane has 1 controller at a time. Another device that asks for control gets the error `another device controls that terminal`.

A read, a reply, and a start can take seconds.
When you unpair the device during that time, `fluxd` does not send the answer.
When you set `herdr = false` during a read, the answer has an error and no text.
When you set `herdr_terminals = false` during the read of a terminal, the answer has an error and no text.
When you set `herdr_control = false` during a live terminal, `fluxd` ends the stream with the code `stopped`.

### Live terminal bridge

For each live terminal of a phone, `fluxd` runs the `herdr` CLI from the `PATH` of `fluxd.service`:

```sh
herdr terminal session control PANE --cols COLS --rows ROWS
```

A stream that only watches the pane runs `observe` in place of `control`.

`HERDR_SOCKET_PATH` in the environment of the CLI selects the herdr session.
The CLI sends the frames of the terminal on its output, and `fluxd` sends them to the phone.
The phone never connects to herdr.

`fluxd` checks the version of the herdr server and of the CLI each time it connects to a herdr server.
It runs `herdr --version` for this check, with a limit of 3 seconds.
When one of the 2 is older than 0.9.3, or `fluxd` cannot run the CLI, the phone gets no live terminal.
The log of `fluxd` and `flux-cli doctor` tell why.

While the check fails, `fluxd` runs it again about once a minute.
It asks the herdr server for its version again, and then it checks the CLI again.
An update of herdr then turns on the live terminal with no restart of `fluxd`.
The log then says that the live terminal on the phone is on, and the phones get the new state.
`fluxd` keeps a check that passed until it connects to a herdr server again.

`fluxd` reads the `PATH` of `fluxd.service` only when it starts.
After a change of that `PATH`, restart `fluxd`:

```sh
systemctl --user restart fluxd
```

`fluxd` answers each open within 15 seconds.
When the phone releases the terminal, `fluxd` sends `terminal.release` to the CLI and closes its input.
herdr then gives the desktop its size back, as [Live terminal on Android](#live-terminal-on-android) describes.
`fluxd` stops a CLI that does not exit within 5 seconds.
The loss of the link, an unpair, and a change of a setting release the terminal in the same way.
When `fluxd` stops a CLI, herdr can keep the pane at the size of the phone.
The log of `fluxd` then says that the terminal session ended with SIGKILL, with the last error line of the CLI.

After an update, `fluxd.service` does not restart into the new binary while a live terminal runs or opens.
The journal then shows the line `the restart waits for the live terminal`.
To let the restart run, stop Live on the phone.

herdr scrolls the terminal to read the history, so `fluxd` does not read the history of a pane while a phone controls it.
A read then gets the cached history and the current screen, as [See your agents](#see-your-agents) describes.
When the phone releases the pane, the next read gets all lines again.
A device that only watches a pane does not change the terminal, so the history stays current.

### Wire format

The packet type is `flux.herdr`.
Both sides send it.
The `kind` field selects the message.

| Kind | Sender | Body |
| --- | --- | --- |
| `state` | Computer | `enabled`, `running`, `control`, `terminals`, `bridge`, `review`, `agents`, `panes`, `workspaces`, and `kinds` |
| `output` | Computer | `pane` and `format`, then `text` and `truncated`, or `error` |
| `sent` | Computer | `pane` and `action`. When the reply failed, also `error`, and `code` for some errors. |
| `created` | Computer | `what`, then `pane` or `error` |
| `closed` | Computer | `pane`, and `error` when the close failed |
| `request` | Phone | No other fields. The computer answers with `state`. |
| `read` | Phone | `pane`, `lines` from 1 to 1000, and `format`. Zero lines means 200. |
| `keys` | Phone | `pane` and `keys`, 1 to 8 key names. The computer answers with `sent`. |
| `prompt` | Phone | `pane`, `text`, and `answer`. The computer answers with `sent`. |
| `input` | Phone | `pane` of a terminal, `text`, and 0 to 8 `keys`. The computer answers with `sent`. |
| `create` | Phone | `what` is `agent` or `terminal`, then `agent`, `cwd`, and `workspace`. The computer answers with `created`. |
| `close` | Phone | `pane`. The computer answers with `closed`. |
| `terminal_open` | Phone | `request`, `pane`, and `mode`, `observe` or `control`. `control` can add `cols` and `rows` of the grid, from 1 to 1000. The computer answers with `terminal_opened`. |
| `terminal_opened` | Computer | `request`, `pane`, and `mode`, then `session`, `width`, and `height`, or `error`. A temporary error also has `retry`. |
| `terminal_frame` | Computer | `session`, `seq`, `encoding`, `full`, `width`, `height`, and `bytes` |
| `terminal_scroll` | Phone | `session`, `direction`, and the zero-based `column` and `row` of a cell |
| `terminal_mouse` | Phone | `session`, `action`, `button`, and the zero-based `column` and `row` of a cell |
| `terminal_resize` | Phone | `session`, `cols`, and `rows`, from 1 to 1000 |
| `terminal_release` | Phone | `session` and `request`. The computer answers with `terminal_closed`. |
| `terminal_closed` | Computer | `session`, `code`, and `reason`. After a release, also the `request` of the release. |
| `terminal_input` | Phone | `session`, and exactly one of `text` or `key` |
| `terminal_input_error` | Computer | `session`, `code`, `error` |

The optional `state.bridge` list advertises `observe`, `control`, `scroll`, `mouse`, and `input`.
Old clients ignore these additive kinds and continue using read/output operations.
Only control may request a phone-sized grid; dimensions are bounded to 1..1000 cells.
Each device has at most one stream and each pane at most one controller, without takeover.
The generated session ID is bound to its device, link, and terminal; stale input is not replayed.

A `terminal_input` types one event in the controller session. `text` goes as it is, on one
line, without a trailing Enter, and can have up to 16 KB. `key` is one of `enter`, `tab`,
`esc`, `backspace`, `up`, `down`, `left`, and `right`; fluxd encodes it, so a client cannot
send an arbitrary escape sequence. fluxd refuses an empty text, both fields, a control
character, or an unknown key with `terminal_input_error` and the code `invalid_input`.
A bridge failure answers with `input_failed` and ends the stream, so a phone cannot keep
typing into a dead controller. An unknown, foreign, or released session gets no input and
no answer. The events keep their order through the controller, so a character, a Tab, and
an Enter arrive in the order they were typed.

Frames contain base64 ANSI bytes and must be applied in order: incremental frames cannot be
dropped or truncated. A full frame establishes the baseline before input is enabled. Its sequence
number is not an acknowledgement of a specific input event. Wheel input uses `source: wheel`
and `lines: 1`; increasing `lines` does not multiply mouse-report events. Mouse clicks use
ordered left-button `down`/`up` events through the existing bridge.

When `fluxd` cannot finish an answer because of an internal error, it sends the answer with an `error`, for example `fluxd could not read the pane`.

A `keys`, `prompt`, `input`, `create`, `close`, `terminal_open`, or `terminal_release` packet can have `request`, a number.
The answer `sent`, `created`, `closed`, `terminal_opened`, or `terminal_closed` has the same `request`, so the phone can match a late answer to its packet.
`terminal_closed` has a `request` only when the phone released the stream.
An answer to a packet without `request` has no `request` field.

The computer sends `state` when the phone connects, after each change, and as the answer to `request`.
Each agent has `pane`, `agent`, `status`, `title`, `project`, and `workspace`:

```json
{"kind":"state","enabled":true,"running":true,"control":false,"agents":[{"pane":"w5:p1","agent":"claude","status":"blocked","title":"Custom skin loading","project":"cliamp","workspace":"cliamp"}]}
```

`status` is `idle`, `working`, `blocked`, `done`, or `unknown`.
`project` is the base name of the agent's working folder.
`control` is `true` when `herdr = true` and `herdr_control = true`.
`terminals` is `true` when `control` is `true` and `herdr_terminals = true`.

`panes` lists the terminals, and it is empty when `terminals` is `false`.
Each terminal has `pane`, `title`, `project`, and `workspace`.
`workspaces` lists the workspaces with `id`, `label`, and `cwd`, the folder of the active tab.
A `cwd` in the home folder starts with `~/`.
`kinds` lists the agent kinds that the computer can start. It has only the agents that can run, as [Start an agent](#start-an-agent) describes.
Both lists are empty when `control` is `false`.

A `create` with `"what":"agent"` names the agent kind in `agent`, for example `claude`.
`cwd` is a full path, `~`, or a path that starts with `~/`. An empty `cwd` is the home folder.
An empty `workspace` opens a new workspace. A workspace ID opens a new tab in that workspace.
The computer sends `state` with the new pane before `created`:

```json
{"kind":"create","what":"agent","agent":"claude","cwd":"~/Code/flux","workspace":""}
{"kind":"created","what":"agent","pane":"w7:p1"}
```

A `read` with `"format":"ansi"` gets an `output` with `"format":"ansi"`.
Its `text` keeps the SGR sequences of colors and styles.
`fluxd` removes all other escape sequences.
It changes CRLF to LF and removes the blanks with the default background at the end of each line.
Blanks with a background stay, because they draw the panels of full-screen agents such as opencode.
Without `format`, `text` has no ANSI codes.
For an agent, `fluxd` also reads the plain history and puts the ANSI screen under it, because herdr gets the history of an agent in the alternate screen only as plain text.
`text` has at most 1 MB.
When `fluxd` removes older lines to stay in that limit, `truncated` is `true`.

In both formats, `fluxd` removes the C0 and C1 control characters except line breaks and tabs.
It changes each bidirectional control character to U+FFFD: U+061C, U+200E, U+200F, U+202A to U+202E, and U+2066 to U+2069.
It also changes the line and paragraph separators U+2028 and U+2029.
The apps show text with the Unicode bidirectional algorithm, and a terminal does not.
So such a character can show a command in a different order on the phone than on the computer.

The `title`, `project`, and `workspace` of the agents and the terminals, and the `label` of the workspaces, get the same changes.
A program sets the title of its pane, and an agent can make its title from the conversation.
In these fields, `fluxd` also changes line breaks and tabs to spaces.

A reply and its answer look like this:

```json
{"kind":"keys","pane":"w5:p1","keys":["2"],"request":7}
{"kind":"sent","pane":"w5:p1","action":"keys","request":7}
```

When the agent waits for a choice, the computer refuses a `prompt` with the code `blocked`:

```json
{"kind":"prompt","pane":"w5:p1","text":"No, use git clean"}
{"kind":"sent","pane":"w5:p1","action":"prompt","error":"The agent waits for a choice. Pick a choice first.","code":"blocked"}
```

To answer a question that needs free text, the app sends the prompt with `"answer":true`.
`fluxd` then checks that the agent still waits, changes the line breaks to spaces, types the text, and presses Enter.
An app sends `answer` only after the user selects an action to type an answer.

`bridge` in `state` lists the live terminal actions that the device can use:

- An empty list when herdr does not run. The list is also empty when the herdr server or the `herdr` CLI of `fluxd` is older than 0.9.3, or `fluxd` cannot run that CLI.
- `["observe"]` without `herdr_control`.
- `["observe","control","scroll","mouse"]` with `herdr_control`.

Flux for Android shows **Live** only when `control` is `true` and `bridge` has `control`.
An older `fluxd` sends no `bridge`, so a new phone shows no **Live** key.
An older app ignores `bridge` and the `terminal_` kinds, and it reads the output as before.

A `terminal_open` with `"mode":"observe"` watches the pane at its size on the computer.
With `"mode":"control"`, the device controls the pane, and `cols` and `rows` set the grid of the pane.
Without `cols` and `rows`, the pane keeps its size.
`session` in `terminal_opened` names the stream.
Only the device and the link that opened a stream can send events to it or release it.
The computer sends `terminal_opened` before the first frame:

```json
{"kind":"terminal_open","pane":"w5:p1","mode":"control","cols":60,"rows":38,"request":12}
{"kind":"terminal_opened","pane":"w5:p1","mode":"control","session":"ts3","width":60,"height":38,"request":12}
```

When `fluxd` refuses an open, `terminal_opened` has an `error`, for example:

- `fluxd does not know that pane`. A pane that the device cannot see gets the same error.
- `replies are off on this computer`, for `control` without `herdr_control`.
- `another device controls that terminal`.
- `fluxd already streams a terminal to this device`.
- `fluxd already opens a terminal for this device. Try again.`
- `fluxd could not open the terminal in time. Try again.`
- `The live terminal needs herdr 0.9.3 or newer on this computer.`

The 2 errors that end with `Try again.` are temporary, and so is `fluxd already streams a terminal to this device`. Their answer also has `"retry": true`:

```json
{"kind":"terminal_opened","pane":"w5:p1","mode":"control","error":"fluxd already opens a terminal for this device. Try again.","retry":true,"request":13}
```

The phone can send the open again after a short wait, and it does not have to compare the text of the error.
`fluxd already streams a terminal to this device` shows while the release of the last stream of the device is still in progress.
The answer with another error has no `retry` field.

`bytes` in `terminal_frame` has the ANSI bytes of the terminal in standard base64, and `encoding` is `ansi`.
A frame can change only a part of the screen, so the phone applies each frame in the order of `seq`.
A frame with `"full":true` draws the whole screen.
Flux for Android shows the terminal and sends gestures only after the first full frame of the stream draws.
`seq` does not acknowledge a scroll or a click.

The input events need a `control` stream:

- `terminal_scroll` sends one wheel step. `direction` is `up` or `down`. `fluxd` sends 1 line with the source `wheel` to herdr, so a device cannot change a scroll into another key.
- `terminal_mouse` sends one mouse event. `action` is `down`, `up`, `drag`, or `move`. `button` is `left`, `right`, or `middle`. Flux for Android sends a left `down` and a left `up` for a tap.
- `terminal_resize` changes the grid of the pane and keeps the stream.

`column` and `row` are zero-based cells of the grid of the stream.
`fluxd` ignores an event for a session that the device and the link did not open.

`terminal_closed` comes after the last frame of the stream.
`code` tells why the stream ended:

| Code | Meaning |
| --- | --- |
| `released` | The phone released the stream. |
| `bridge` | The herdr CLI ended the stream. |
| `agent_ended` | The agent left the pane. |
| `pane_closed` | The pane closed or moved. |
| `stopped` | `fluxd` stopped the stream, for example because herdr stopped, a setting changed, or the link failed. |

`reason` has the text of the end, and it is never empty.
When `fluxd` stopped a herdr CLI that did not exit, `reason` can be `herdr: the terminal session ended with SIGKILL`.

`flux-cli status --json` includes the same agent state in its `herdr` field.
It also has `cli` with the `path`, the `version`, and the `error` of the version check of the herdr CLI. The phone does not get `cli`.

## Troubleshoot

| Problem | Next step |
| --- | --- |
| The **Agents and terminals** tile is missing | Update `fluxd` and Flux for Android. The tile shows in **Control** only when the computer sends `flux.herdr`. |
| The phone says that herdr is not running | Run `herdr status` and `flux-cli doctor` on the computer. |
| The list is empty | Run `herdr agent list`. herdr must detect the agent in its pane. |
| The phone says that the feature is off | Set `herdr = true` and reload `fluxd`. |
| The phone says that replies are off | Set `herdr_control = true` and reload `fluxd`. |
| The add button is missing on the **Agents** screen | Set `herdr_control = true` and reload `fluxd`. herdr must run. |
| The phone says that terminals are off | Set `herdr_control = true` and `herdr_terminals = true`, then reload `fluxd`. |
| An agent kind is missing from the list | Run the agent once in a terminal, so that mise installs it. Then wait 1 minute. The command must also be in the `PATH` of `fluxd`. Run `systemctl --user show-environment` to see that `PATH`. |
| A new agent says that it did not start | Read the last line in the error. Run the agent command in a terminal on the computer to see the problem. |
| The output shows a dim line about more lines | The agent works, and more lines came than one screen. The phone reads them when the agent stops. |
| The output shows a dim line about the release of the phone | A phone controls the agent in Live. The older lines update when the phone releases the agent. |
| The **Live** key is missing on the agent screen | Run `flux-cli doctor` on the computer. Live needs herdr 0.9.3 or newer for the server and for the herdr CLI of `fluxd`, and `herdr_control = true`. Update `fluxd` and Flux for Android. The key does not show in the **Changes** view. |
| Live says that the live terminal did not open | Read the error in the line above the output. Then read the herdr messages of the daemon, as the end of this page shows. |
| Live says `The live terminal stopped. Tap Live to try again.` | Live tried again 4 times, and each try failed. Or Android stopped the page of the terminal. Select **Live** to try again. If Live stops again, read the herdr messages of the daemon. |
| Live says that the computer stopped the live terminal | `fluxd` stopped the stream. A change of `herdr_control`, `herdr_terminals`, or the access of the device does this. A herdr server that stops also does this. Check the settings, then select **Live** again. |
| Live says to set a screen lock | Set a PIN, a pattern, or a password on the phone. |
| The pane on the computer keeps the size of the phone after Live | At the release, the desktop had no attached herdr client. The next herdr client that attaches sets the size. When the log of `fluxd` says that the terminal session ended with SIGKILL, the herdr CLI did not exit after the release. Attach a herdr client on the desktop again to set the size. |
| A reply says that the agent is not ready for input | herdr accepts input only for an agent that it detected. Run `herdr agent get PANE` on the computer. |
| A reply says that the agent waits for a choice | The agent shows a dialog. Pick a choice with the choice buttons or the key bar, then send the text again. |
| The log says that the herdr socket belongs to another user | Another user listens on the herdr socket path. Set `HERDR_SOCKET_PATH` to a socket in a folder that only you can write to. |
| The mic key is missing | The phone has no speech recognizer. Install Speech Recognition and Synthesis from Google, or another voice input app. |
| The **Agents and terminals** tool is missing on the Mac | Update `fluxd` and Flux for macOS. The tool shows in **Control** only when a computer in the scope accepts `flux.herdr`. |
| Dictation on the Mac says to allow Speech Recognition or the microphone | Select **Open Privacy Settings**, allow Flux, then start the dictation again. |
| Dictation on the Mac sends the audio to Apple | The Mac has no speech model for the language. Add the language under **Dictation** in **System Settings > Keyboard**, or choose a language under **On this Mac**. |
| Dictation says that Android downloads the speech model | Wait until the download is done, then start the dictation again. |
| Dictation says that the recognizer supports none of the phone languages | Select **Choose a language** under the field, then download a language in the picker. |
| Dictation uses the wrong language | Select the language button in the panel header, then select the language that you want. |
| Dictation says to stop Flux Microphone | Stop the microphone on the **Microphone** screen or in **Webcam** mode, then start the dictation again. |

To read the herdr messages of the daemon, run:

```sh
journalctl --user -u fluxd --no-pager | grep herdr
```
