// The Flux menu entries. The sending itself is in host.js, which this file
// loads.

if (typeof importScripts === "function") importScripts("host.js");

// One entry for each thing that the browser can offer a link from.
const MENUS = [
  { id: "send-link", title: "menuSendLink", contexts: ["link"] },
  { id: "send-page", title: "menuSendPage", contexts: ["page"] },
];

// Remove the old entries first, so that a new version of the extension
// does not leave two copies of every entry behind.
function buildMenus() {
  chrome.contextMenus.removeAll(() => {
    for (const menu of MENUS) {
      const { title, ...rest } = menu;
      chrome.contextMenus.create({ ...rest, title: flux.t(title) });
    }
  });
}

chrome.runtime.onInstalled.addListener(buildMenus);
chrome.runtime.onStartup.addListener(buildMenus);

chrome.contextMenus.onClicked.addListener((info, tab) => {
  switch (info.menuItemId) {
    case "send-link":
      flux.send(info.linkUrl);
      break;
    case "send-page":
      flux.send(info.pageUrl || (tab && tab.url));
      break;
  }
});
