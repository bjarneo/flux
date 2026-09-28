# herdr agents

[Documentation index](README.md)

Flux for Android and Flux for macOS show the coding agents that [herdr](https://herdr.dev) runs on your Omarchy computer.
You can see the status of each agent, read its recent output in color, and get a notification when an agent needs input or finishes.
When you turn on replies, you can also answer an agent with taps and send it text.

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

The output screen shows up to 200 lines of recent output with the colors and styles of the terminal.
It reads the output again every 5 seconds while the agent works, and after each status change.
Select refresh to read it at once.
herdr keeps only the recent part of the terminal for some agents, so the screen can show fewer lines.

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

- The page of the computer has an **Agents** card. It lists the first agents and shows the number of blocked agents.
- **Open Agents…** opens a window with the agent list on the left and the output of the selected agent on the right. The menu bar item has **Agents…** too.
- The output uses the colors of Tokyo Night in dark mode and Tokyo Night Day in light mode.
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
With `herdr_control = true`, it can also send the keys in the list above and prompts to an agent.
An agent can run commands, so a reply has the same power as a prompt that you type on the computer.
`fluxd` reads and sends only to panes that hold an agent in the last agent list.
herdr also checks that an agent is in the pane before it sends a key or a prompt.

`fluxd` logs each reply with the device name, the pane, and the keys.
For a prompt, it logs the number of characters, not the text.

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
| `state` | Computer | `enabled`, `running`, `control`, and `agents` |
| `output` | Computer | `pane` and `format`, then `text` and `truncated`, or `error` |
| `sent` | Computer | `pane` and `action`, and `error` when the reply failed |
| `request` | Phone | No other fields. The computer answers with `state`. |
| `read` | Phone | `pane`, `lines` from 1 to 400, and `format`. Zero lines means 200. |
| `keys` | Phone | `pane` and `keys`, 1 to 8 key names. The computer answers with `sent`. |
| `prompt` | Phone | `pane` and `text`. The computer answers with `sent`. |

The computer sends `state` when the phone connects, after each change, and as the answer to `request`.
Each agent has `pane`, `agent`, `status`, `title`, `project`, and `workspace`:

```json
{"kind":"state","enabled":true,"running":true,"control":false,"agents":[{"pane":"w5:p1","agent":"claude","status":"blocked","title":"Custom skin loading","project":"cliamp","workspace":"cliamp"}]}
```

`status` is `idle`, `working`, `blocked`, `done`, or `unknown`.
`project` is the base name of the agent's working folder.
`control` is `true` when `herdr = true` and `herdr_control = true`.

A `read` with `"format":"ansi"` gets an `output` with `"format":"ansi"`.
Its `text` keeps the SGR sequences of colors and styles.
`fluxd` removes all other escape sequences and control characters, changes CRLF to LF, and removes the blanks at the end of each line.
Without `format`, `text` has no ANSI codes.
`text` has at most 256 KB.
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
