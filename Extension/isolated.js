// Relays between the page's main world (main-world.js) and the extension background.
(() => {
  const BUILD = '__BUILD_ID__'; // replaced by the build script; must match main-world.js
  if (window.__lcxIsolated === BUILD) return;
  window.__lcxIsolated = BUILD;
  const CMD_EVENT = 'lcxmixer:cmd:' + BUILD;
  const STATE_EVENT = 'lcxmixer:state:' + BUILD;
  const ok = () => { try { return !!chrome.runtime && !!chrome.runtime.id; } catch (e) { return false; } };

  document.addEventListener(STATE_EVENT, (e) => {
    if (!ok()) return;
    let state;
    try { state = JSON.parse(e.detail); } catch (err) { return; }
    chrome.runtime.sendMessage({ type: 'frameState', state }).catch(() => {});
  });

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg && msg.type === 'cmd') {
      document.dispatchEvent(new CustomEvent(CMD_EVENT, { detail: JSON.stringify(msg) }));
    }
  });

  // Ask the main world for its current state (it may have loaded first).
  document.dispatchEvent(new CustomEvent(CMD_EVENT, { detail: JSON.stringify({ action: 'report' }) }));
})();
