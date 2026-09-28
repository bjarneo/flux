// The Flux client that the extension shares. It starts the Flux native
// messaging host and asks it to send a link to the phone, so that the
// extension never touches the network itself.
//
// Chromium loads this into the service worker with importScripts, and
// Firefox lists it in background.scripts. The popup loads it as a plain
// script, so it must stay a classic script with one global.

const flux = (() => {
  const HOST = "org.omarchy.flux";
  const PICKED = "picked";
  const BADGE = { busy: "…", sent: "✓", failed: "!" };

  // t is a string from _locales, in the language of the browser. A key
  // that no locale has comes back as the key itself, which is easier to
  // spot than an empty button.
  function t(key, subs) {
    return chrome.i18n.getMessage(key, subs) || key;
  }

  // ask sends one message to the Flux host and resolves with its reply.
  // The host answers once and then waits for more, so the reply itself is
  // what ends the wait: a disconnect only comes when we ask for it, or when
  // the host dies without answering.
  function ask(request) {
    return new Promise((resolve, reject) => {
      const port = chrome.runtime.connectNative(HOST);
      let done = false;
      const finish = (settle, value) => {
        if (done) return;
        done = true;
        settle(value);
      };

      // A native port hands the message over as it is, with no event
      // around it, as JSON text or already parsed.
      port.onMessage.addListener((data) => {
        if (typeof data === "string") {
          try {
            finish(resolve, JSON.parse(data));
          } catch {
            finish(reject, new Error(t("notJSON")));
          }
        } else {
          finish(resolve, data);
        }
        port.disconnect();
      });
      port.onDisconnect.addListener(() => {
        // A host that never answers is the one case that
        // `flux-cli browser install` fixes.
        const why = chrome.runtime.lastError;
        finish(reject, new Error(why ? why.message : t("didNotAnswer")));
      });
      port.postMessage(request);
    });
  }

  function stored(key) {
    return new Promise((resolve) => chrome.storage.local.get(key, (all) => resolve(all[key] || "")));
  }

  // remember writes a value and waits for the browser to have it, so that
  // a caller can read it back straight after. The phone that the user
  // marked in the popup is the only thing that Flux keeps this way.
  function remember(key, value) {
    return new Promise((resolve) => chrome.storage.local.set({ [key]: value }, resolve));
  }

  // reason returns the message of a refused request, in the words of Flux.
  function reason(reply) {
    return (reply && reply.error && reply.error.message) || "Flux did not do it";
  }

  // phones lists the paired phones, the connected ones first.
  async function phones() {
    const reply = await ask({ command: "devices" });
    if (!reply.ok) throw new Error(reason(reply));
    return (reply.devices || []).sort((a, b) => Number(b.online) - Number(a.online));
  }

  // phoneFor picks the phone for a send from the menu or the keyboard: the
  // one that the user marked, and otherwise the only connected phone. With
  // several connected phones and no choice yet, the popup is the only place
  // that can ask.
  async function phoneFor() {
    const all = await phones();
    if (!all.length) throw new Error(t("noPhonePaired"));
    const picked = await stored(PICKED);
    if (picked) {
      const found = all.find((p) => p.id === picked);
      if (found) return found;
    }
    const online = all.filter((p) => p.online);
    if (online.length === 1) return online[0];
    if (all.length === 1) return all[0];
    throw new Error(t("moreThanOnePhone"));
  }

  // send puts a link on the phone and shows the result in the icon, because
  // a menu click has no window to show it in. It returns the message for
  // the caller to show.
  async function send(url, phone) {
    if (!/^https?:\/\//.test(url || "")) {
      return report(BADGE.failed, t("onlyWebLinks"));
    }
    mark(BADGE.busy, t("sending"));
    try {
      const target = phone || (await phoneFor());
      const reply = await ask({ command: "send", url, device: target.id });
      if (!reply.ok) throw new Error(reason(reply));
      return report(BADGE.sent, t("sentTo", [target.name]));
    } catch (err) {
      return report(BADGE.failed, err.message);
    }
  }

  // mark shows the result in the icon for a few seconds, and keeps it in
  // the tooltip until the next send.
  function mark(text, title) {
    chrome.action.setBadgeText({ text });
    chrome.action.setTitle({ title: `Flux: ${title}` });
    setTimeout(() => chrome.action.setBadgeText({ text: "" }), 2500);
  }

  function report(text, title) {
    mark(text, title);
    if (text === BADGE.failed) console.warn("Flux:", title);
    return title;
  }

  // activeTab gives the URL of the tab that the user is on, without asking
  // for the browsing history.
  function activeTab() {
    return new Promise((resolve) => chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => resolve(tabs[0] || null)));
  }

  return {
    HOST,
    PICKED,
    activeTab,
    ask,
    mark,
    phoneFor,
    phones,
    remember,
    send,
    stored,
    t,
  };
})();
