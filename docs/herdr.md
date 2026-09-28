# herdr agents

[Documentation index](README.md)

Flux for Android and Flux for macOS show the coding agents that [herdr](https://herdr.dev) runs on your Omarchy computer.
You can see the status of each agent, read its recent output in color, and get a notification when an agent needs input or finishes.
When you turn on control, you can also answer an agent with taps, send it text, start new agents, and close agents.
When you also turn on terminals, Flux for Android opens herdr terminals and types commands in them.

The phone uses the Flux link that it already has.
It needs no new port, no firewall rule, and no new pairing.
This page describes the phone. A Mac works the same way, and [Use a Mac](#use-a-mac) describes where it differs.

```text
herdr server ── Unix socket ── fluxd ── Flux TLS link ── Flux for Android
```

`fluxd` is the only herdr client.
The phone never connects to the herdr socket.

## Requirements

- herdr with API protocol 22 or newer. herdr 0.9.1 uses protocol 22.
- herdr and `fluxd` run as the same desktop user.
- A `fluxd` and a Flux for Android or Flux for macOS that both include this feature.

To check the desktop side, run:

```sh
flux-cli doctor
```

When herdr runs, `flux-cli doctor` prints this line:

```text
✓ herdr 0.9.1 runs, so the phone can show its agents
```

## See your agents

1. Start herdr on the computer.
2. Open Flux for Android and select the computer.
3. Select **Agents**.
4. Select an agent to read its recent output.

The list puts blocked agents first, then done, working, idle, and unknown agents.
A blocked agent waits for an approval or for the answer to a question.
Idle and done agents are ready for new input.
The **Agents** tile shows the number of blocked agents.

The output screen of the phone shows up to 1000 lines of recent output.
The screen part of the output has the colors and styles of the terminal.
The older lines above it are plain text.
It reads the output again every 5 seconds while the agent works, and after each status change.
Select refresh to read it at once.

When you scroll up to read older lines, the screen stays there when new output comes.
To go back to the newest lines, select the arrow at the bottom of the output.

Many agents, such as Claude Code, draw in the alternate screen of the terminal.
herdr gets the older lines of such an agent only while the agent is idle, and only as plain text.
While the agent works, the phone shows the older lines from the last idle read above the current screen.
When the two parts do not meet, a dim line says that more lines show when the agent stops.
The phone reads all lines again when the agent stops.
herdr keeps only the recent part of the terminal for some agents, so the screen can show fewer lines.

The phone fits the output to its narrow screen.
This matters most for full-screen agents such as opencode, which draw panels across the full terminal:

- A long line wraps, and its wrapped rows start under its text, after the panel bar or the list marker.
- The phone removes the margin that all lines share, extra empty rows, scroll bars, and the half-block edges of boxes.
- A panel, for example a message, a tool call, or a diff line in opencode, fills the width of the screen.
- The phone removes the sidebar that opencode shows in a wide terminal, because its rows share the lines of the conversation. The status line at the bottom still shows the tokens and the cost.
- A centered drawing, for example the opencode logo, moves to the left when that makes it fit.
- When the agent colors suit a dark background and the phone uses the light theme, the phone inverts the lightness of these colors, so the text stays readable. It does the same for colors that suit a light background in the dark theme.

## Notifications

The phone posts a notification when an agent changes to blocked.
It also posts a notification when an agent changes from working to done or idle.
A tap opens the output of that agent.

The phone does not post notifications for the first agent list after it connects.
It waits 2 seconds before a finished notification, because the status can change between tool calls.
When the agent works again, the phone removes its notification.

To turn off a notification type, use the **Agent needs input** or **Agent finished** switch on the phone's device page.
The switches apply to all computers.
Android also lists the two types as the **Agents that need input** and **Agents that finish** channels.

## Answer an agent

Replies are off by default, because an agent can run commands on the computer.
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
- The text field sends a prompt to the agent. When the agent is blocked, the phone types the text and presses Enter, which answers a question that needs free text.

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
When the agent does not start, `fluxd` closes the new pane and the phone shows the last line of the shell, for example `command not found`.

A new agent in a new folder can ask if you trust the folder.
The agent is then blocked, and the phone shows the choices.

## Close an agent

With `herdr_control = true`, select **Close** on the screen of an agent, then confirm.
herdr closes the pane, and the agent in it stops.
When the pane is the last one of its tab, herdr also closes the tab.
When the tab is the last one of its workspace, herdr also closes the workspace.

## Use terminals

Terminals give the phone a shell on the computer, so they are off by default.
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
Select a terminal to see its output and to type in it:

- Type a command in the field, then select **Run**. The phone types the command and presses Enter.
- To speak a command, select the mic key next to **Run**. The command goes in at the cursor without the capital and the period of a sentence. Read it, then select **Run**.
- The key bar sends Esc, Tab, Ctrl-C, Ctrl-D, Up, Down, and Enter.
- The screen reads the output again every 3 seconds.
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
It shows up to 200 lines of output.
It does not start agents, close them, or open terminals.

- The page of the computer has an **Agents** card. It lists the first agents and shows the number of blocked agents.
- **Open Agents…** opens a window with the agent list on the left and the output of the selected agent on the right. The menu bar item has **Agents…** too.
- The output uses the colors of Tokyo Night in dark mode and Tokyo Night Day in light mode.
- The Mac does not yet fit the output of full-screen agents such as opencode, as the phone does.
- Press Command-R to read the output again.
- Return sends the text. Shift-Return adds a line break.
- Before the first reply, the Mac asks for Touch ID or the Mac password. The unlock stays valid for 5 minutes while Flux runs.
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
With `herdr_control = true`, it can also send the keys in the list above and prompts to an agent, start agents, and close agent panes.
An agent can run commands, so a reply has the same power as a prompt that you type on the computer.
`fluxd` reads and sends only to panes that hold an agent in the last agent list.
herdr also checks that an agent is in the pane before it sends a key or a prompt.

With `herdr_terminals = true` and `herdr_control = true`, the phone can also read, type in, open, and close each herdr pane that has no agent.
A terminal is a shell, so the phone can then run any command as your user.
Turn it on only for phones that you trust.

`fluxd` logs each reply with the device name, the pane, and the keys.
For a prompt and a terminal command, it logs the number of characters, not the text.
It also logs each new agent, new terminal, and closed pane.

Terminal output can contain secrets.
The output goes only to paired phones over the Flux TLS link.
`fluxd` does not write the output to its log.

## How it works

`fluxd` subscribes to herdr events for new agents, closed panes, moved panes, and workspace changes.
It also subscribes to the status of each agent pane, because herdr needs a pane ID for that event.
After each event, `fluxd` reads the session snapshot and sends the agent list when it changed.
It also reads the snapshot every 10 seconds, which finds title changes.

When herdr stops, `fluxd` tries to connect every 5 seconds.
When the phone opens the agent list, `fluxd` tries at once.

### Wire format

The packet type is `flux.herdr`.
Both sides send it.
The `kind` field selects the message.

| Kind | Sender | Body |
| --- | --- | --- |
| `state` | Computer | `enabled`, `running`, `control`, `terminals`, `agents`, `panes`, `workspaces`, and `kinds` |
| `output` | Computer | `pane` and `format`, then `text` and `truncated`, or `error` |
| `sent` | Computer | `pane` and `action`, and `error` when the reply failed |
| `created` | Computer | `what`, then `pane` or `error` |
| `closed` | Computer | `pane`, and `error` when the close failed |
| `request` | Phone | No other fields. The computer answers with `state`. |
| `read` | Phone | `pane`, `lines` from 1 to 1000, and `format`. Zero lines means 200. |
| `keys` | Phone | `pane` and `keys`, 1 to 8 key names. The computer answers with `sent`. |
| `prompt` | Phone | `pane` and `text`. The computer answers with `sent`. |
| `input` | Phone | `pane` of a terminal, `text`, and 0 to 8 `keys`. The computer answers with `sent`. |
| `create` | Phone | `what` is `agent` or `terminal`, then `agent`, `cwd`, and `workspace`. The computer answers with `created`. |
| `close` | Phone | `pane`. The computer answers with `closed`. |

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
`fluxd` removes all other escape sequences and control characters, changes CRLF to LF, and removes the blanks with the default background at the end of each line.
Blanks with a background stay, because they draw the panels of full-screen agents such as opencode.
Without `format`, `text` has no ANSI codes.
For an agent, `fluxd` also reads the plain history and puts the ANSI screen under it, because herdr gets the history of an agent in the alternate screen only as plain text.
`text` has at most 1 MB.
When `fluxd` removes older lines to stay in that limit, `truncated` is `true`.

A reply and its answer look like this:

```json
{"kind":"keys","pane":"w5:p1","keys":["2"]}
{"kind":"sent","pane":"w5:p1","action":"keys"}
```

`flux-cli status --json` includes the same agent state in its `herdr` field.

## Troubleshoot

| Problem | Next step |
| --- | --- |
| The **Agents** tile is missing | Update `fluxd` and Flux for Android. The tile shows only when the computer sends `flux.herdr`. |
| The phone says that herdr is not running | Run `herdr status` and `flux-cli doctor` on the computer. |
| The list is empty | Run `herdr agent list`. herdr must detect the agent in its pane. |
| The phone says that the feature is off | Set `herdr = true` and reload `fluxd`. |
| The phone says that replies are off | Set `herdr_control = true` and reload `fluxd`. |
| The add button is missing on the **Agents** screen | Set `herdr_control = true` and reload `fluxd`. herdr must run. |
| The phone says that terminals are off | Set `herdr_control = true` and `herdr_terminals = true`, then reload `fluxd`. |
| An agent kind is missing from the list | Run the agent once in a terminal, so that mise installs it. Then wait 1 minute. The command must also be in the `PATH` of `fluxd`. Run `systemctl --user show-environment` to see that `PATH`. |
| A new agent says that it did not start | Read the last line in the error. Run the agent command in a terminal on the computer to see the problem. |
| The output shows a dim line about more lines | The agent works, and more lines came than one screen. The phone reads them when the agent stops. |
| A reply says that the agent is not ready for input | herdr accepts input only for an agent that it detected. Run `herdr agent get PANE` on the computer. |
| The mic key is missing | The phone has no speech recognizer. Install Speech Recognition and Synthesis from Google, or another voice input app. |
| The **Agents** card is missing on the Mac | Update `fluxd` and Flux for macOS. The card shows only when the computer accepts `flux.herdr`. |
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
