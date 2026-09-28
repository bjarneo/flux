// The Flux popup: the phones that Flux knows and a button to send the page
// that the user is on. The sharing itself is in host.js.

const phones = document.getElementById("phones");
const note = document.getElementById("note");
const page = document.getElementById("page");
const state = document.getElementById("state");
const footer = document.getElementById("footer");

// The popup has its own language, from the browser, like the rest of the
// extension.
const t = flux.t;

// tab is the page that the user is on. Its URL comes from activeTab, which
// needs no permission for the browsing history.
let tab = null;

function say(text, bad) {
  note.textContent = text || "";
  note.className = bad ? "note bad" : "note";
}

document.title = t("extName");
document.documentElement.lang = chrome.i18n.getUILanguage();
document.querySelector("h1").textContent = t("extName");

function showPage() {
  const url = (tab && tab.url) || "";
  if (!/^https?:\/\//.test(url)) {
    page.textContent = url ? t("popupNoAddress") : t("popupNoPage");
    return false;
  }
  let host = url;
  try {
    host = new URL(url).host + new URL(url).pathname;
  } catch {
    // A URL that the browser shows but that does not parse still goes to
    // the phone, so keep the whole string.
  }
  page.textContent = (tab.title ? tab.title + " — " : "") + host;
  page.title = url;
  return true;
}

// row builds one phone with a radio that marks it as the phone for the menu
// and a button that sends the page to it right now.
function row(phone, marked) {
  const li = document.createElement("li");

  const radio = document.createElement("input");
  radio.type = "radio";
  radio.name = "phone";
  radio.checked = marked;
  radio.title = t("popupPickPhone");
  radio.addEventListener("change", () => flux.remember(flux.PICKED, phone.id));

  const who = document.createElement("div");
  who.className = "who";
  const name = document.createElement("b");
  name.textContent = phone.name;
  const where = document.createElement("span");
  where.textContent = phone.online ? t("popupOnline") : t("popupOffline");
  who.append(name, where);

  const send = document.createElement("button");
  send.textContent = t("popupSendPage");
  send.addEventListener("click", async () => {
    send.disabled = true;
    say(t("popupSending", [phone.name]));
    say(await flux.send(tab && tab.url, phone));
    send.disabled = false;
  });

  li.append(radio, who, send);
  return li;
}

async function load() {
  tab = await flux.activeTab();
  const web = showPage();
  try {
    const all = await flux.phones();
    const picked = await flux.stored(flux.PICKED);
    const marked = picked || (all.find((p) => p.online) || all[0] || {}).id;
    for (const phone of all) phones.append(row(phone, phone.id === marked));
    if (marked) flux.remember(flux.PICKED, marked);
    state.textContent = t("popupConnected", [all.filter((p) => p.online).length, all.length]);
    if (!all.length) {
      say(t("popupNoPhone"));
    } else if (!web) {
      say(t("popupNoWeb"));
    } else {
      footer.textContent = t("popupHint");
    }
  } catch (err) {
    state.textContent = "";
    say(err.message, true);
    footer.textContent = t("hostNotInstalled");
  }
}

load();
