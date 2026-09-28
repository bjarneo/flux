# Browser extension

[Documentation index](README.md)

The Flux extension sends a link or a web page to your phone, from the right-click menu.
It talks to `fluxd` through a native messaging host, so it needs no network access of its own and works on the same link the CLI uses.

## What it does

- **Send a link or the page you are on** to a paired phone, from the right-click menu or from the icon.

The extension follows the language of the browser, with English and Spanish so far.

## Install

The extension needs two halves: the native messaging host, which the browser starts, and the extension itself, which the browser loads.

1. Write the host manifests for the browsers you have:

   ```sh
   flux-cli browser install
   ```

2. Load the extension, unpacked, in each browser you want it in.

   | Browser | Where |
   | --- | --- |
   | Chromium, Chrome, Brave, Edge, Vivaldi, Opera | The extensions page, then **Developer mode**, then **Load unpacked** |
   | Firefox, Zen | `about:debugging#/runtime/this-firefox`, then **Load Temporary Add-on**, then `manifest.firefox.json` |

`flux-cli browser install` prints the folder to load.
It writes the host manifest for every browser in one pass, with the ID that browser expects: the extension ID for Chromium, and the add-on ID for Firefox and Zen.
That add-on ID is fixed in `manifest.firefox.json`, so the manifest does not change from one profile to the next.

The folder to load is `/usr/share/flux/browser-extension`, or `~/.local/share/flux/browser-extension` after a user install.
It is unpacked on purpose: a browser refuses an extension it cannot verify, and a folder needs no signature.

## Use it

| Action | How |
| --- | --- |
| Send a link | Right-click it, then **Send this link to the phone with Flux** |
| Send the page you are on | Right-click the page, then **Send this page to the phone with Flux**, or **Send page** in the icon |
| Send to another phone | Mark it with the radio button in the icon first |

The icon shows the result of a send: **…** while it works, **✓** when it is on the phone, and **!** when it is not.
The tooltip keeps the message until the next one.

The phone that the icon marks is the one that a menu click sends to, and Flux stores that choice in the browser profile.
With no choice yet, a send goes to the only connected phone, and with several connected it says so and asks for a mark in the icon.

## Remove it

```sh
flux-cli browser remove
```

Then remove the extension from each browser the same way you loaded it.
The host manifests go, and nothing else does.

`--dry-run` shows what a command would write or remove, which is worth doing before the first install on a machine with many browsers.

## How it works

The extension is a plain WebExtension with no background page beyond a service worker, and it declares four permissions: `activeTab`, `contextMenus`, `nativeMessaging`, and `storage`.

It never opens a socket of its own. Each message goes to the native host `org.omarchy.flux`, which is the `flux-native` binary that Flux installs next to the CLI.
That host reads one message, asks `fluxd` over the Unix socket, and writes one reply:

| Command | What it does |
| --- | --- |
| `{"command":"devices"}` | Lists the paired phones, so the icon can show them |
| `{"command":"send","url":…,"device":…}` | Sends a web link to one phone |

The host is the boundary that matters. The browser only ever starts `flux-native`, that binary only talks to the local socket, and the host manifest names one extension ID as the only allowed caller.
A web page cannot reach it: the extension never opens a socket, and only a `chrome-extension://` origin with that ID may connect.

The same message goes to a phone as `flux url` sends it, so `share.url` in the daemon does all the work.
A link that is not `http` or `https` is refused before the host is started, and a link over 8 KiB is refused rather than cut, because half a link goes nowhere.

## Troubleshooting

| Message | What it means |
| --- | --- |
| Flux did not answer. Run: flux-cli browser install | The browser has the host manifest from a different install, or none at all. Run the command again, and reload the extension. |
| Flux sends web links only | A `chrome://` page, or a page that is not a web address. Flux shares web links. |
| The icon stays on **…** | The host is running but the daemon is not answering. Check `flux-cli status`. |
| Nothing happens on the phone | The phone is out of battery saver, or Flux is off. `flux-cli status` shows the link. |

`flux-cli doctor` checks the daemon and the phone.
For the browser half, `flux-cli browser install --dry-run` shows whether the manifests are where the browser looks for them.

## Build it

```sh
make browser
```

That writes two zip files to `browser/dist`: `flux-chromium.zip` and `flux-firefox.zip`, each with the version of the build in the manifest.
The Arch package does not use them: it installs the extension unpacked, as described above.

Firefox and Zen get a different manifest, because they need an add-on ID and a list of background scripts instead of a service worker.
Both manifests come from the same files, so a change to the extension needs only one edit.
