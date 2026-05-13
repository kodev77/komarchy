import { addTab } from "./storage.js";

// Keep chromium's built-in action-click → panel-open behavior on. The
// open path goes through chromium's internal handler, which both opens
// the side panel and moves *frame focus* to it — something our manual
// sidePanel.open() can't replicate. The toggle-on-second-press
// downside is dodged from the outside: bm-ext-focus checks via CDP
// whether the panel is already open and uses CDP.activateTarget for
// refocus (no action key sent), so we never press the action key with
// the panel already open.
chrome.sidePanel
  .setPanelBehavior({ openPanelOnActionClick: true })
  .catch((e) => console.error("setPanelBehavior failed", e));

chrome.commands.onCommand.addListener(async (command, callerTab) => {
  if (command === "save-current-tab") {
    const tab =
      callerTab ??
      (await chrome.tabs.query({ active: true, lastFocusedWindow: true }))[0];
    if (!tab?.url) return;
    // Workspace + group defaults match the python `bm save` shape; the side
    // panel can override later via its own UI commands.
    await addTab({
      id: crypto.randomUUID().replace(/-/g, ""),
      title: tab.title ?? tab.url,
      url: tab.url,
      group: "Unsorted",
      added: new Date().toISOString().slice(0, 10),
    });
    // TODO(v1): broadcast "store changed" to side panel so it re-renders.
  }
});
