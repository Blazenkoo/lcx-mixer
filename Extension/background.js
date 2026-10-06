// LCX Mixer background worker: reports Chrome tabs to the Mac app and carries out its commands.
const HOST = 'org.lcxmixer.app';
const BUILD = '__BUILD_ID__'; // replaced by the build script

// Twitch live streams can't be resumed reliably while their tab is in the background, so
// "pause" there silences the tab and keeps the stream live; "play" unsilences it.
const softPaused = new Set();      // tabIds
const appMuted = new Map();        // tabId -> mute state the app asked for

let port = null;
let appConnected = false;
const frameStates = new Map(); // tabId -> Map(frameId -> state)
let snapshotTimer = null;

function connect() {
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    setTimeout(connect, 5000);
    return;
  }
  port.onMessage.addListener(onAppMessage);
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    if (err) console.warn('LCX Mixer bridge disconnected:', err.message);
    port = null;
    appConnected = false;
    setTimeout(connect, 5000);
  });
}

function scheduleSnapshot(delay = 80) {
  if (snapshotTimer) return;
  snapshotTimer = setTimeout(() => {
    snapshotTimer = null;
    sendSnapshot();
  }, delay);
}

async function sendSnapshot() {
  if (!port || !appConnected) return;
  const tabs = await chrome.tabs.query({});
  const windows = new Map((await chrome.windows.getAll()).map((w) => [w.id, w]));
  const list = tabs.map((t) => {
    const frames = frameStates.get(t.id);
    let hasMedia = false;
    let playing = false;
    let canVolume = false;
    let volume = null;
    let twitchLive = false;
    let volumeIsPosition = false;
    let canSpeed = false;
    let canSeek = false;
    let speed = 1;
    if (frames) {
      for (const s of frames.values()) {
        if (s.twitchLive) twitchLive = true;
        if (s.hasMedia) hasMedia = true;
        if (s.canSpeed) { canSpeed = true; if (typeof s.speed === 'number') speed = s.speed; }
        if (s.canSeek) canSeek = true;
        if (s.playing) playing = true;
        if (s.canVolume && typeof s.volume === 'number') {
          canVolume = true;
          if (s.volumeIsPosition) volumeIsPosition = true;
          if (volume === null || s.playing) volume = s.volume;
        }
      }
    }
    return {
      id: t.id,
      windowId: t.windowId,
      title: t.title || '',
      url: t.url || t.pendingUrl || '',
      // Icons come from Chrome's local favicon cache as data URLs, so the app never goes online.
      favIconUrl: (t.audible || hasMedia) ? faviconFor(t.url || '') : '',
      audible: !!t.audible,
      muted: softPaused.has(t.id) ? !!appMuted.get(t.id) : !!(t.mutedInfo && t.mutedInfo.muted),
      hasMedia,
      playing: playing && !softPaused.has(t.id),
      twitchLive,
      windowBounds: (t.audible || hasMedia) && windows.has(t.windowId)
        ? (({ left, top, width, height }) => ({ left, top, width, height }))(windows.get(t.windowId))
        : null,
      volumeIsPosition,
      canSpeed,
      canSeek,
      speed,
      canVolume,
      volume,
    };
  });
  try { port.postMessage({ type: 'tabs', tabs: list, extensionBuild: BUILD }); } catch (e) { /* port closed */ }
}

const faviconCache = new Map(); // origin -> data URL, or 'pending'

function faviconFor(url) {
  let origin;
  try { origin = new URL(url).origin; } catch (e) { return ''; }
  if (!/^https?:/.test(origin)) return '';
  const cached = faviconCache.get(origin);
  if (cached && cached !== 'pending') return cached;
  if (!cached) {
    faviconCache.set(origin, 'pending');
    loadFavicon(url, origin);
  }
  return '';
}

async function loadFavicon(url, origin) {
  try {
    const src = chrome.runtime.getURL('/_favicon/') + '?pageUrl=' + encodeURIComponent(url) + '&size=64';
    const blob = await (await fetch(src)).blob();
    const bytes = new Uint8Array(await blob.arrayBuffer());
    let binary = '';
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    faviconCache.set(origin, 'data:' + (blob.type || 'image/png') + ';base64,' + btoa(binary));
    scheduleSnapshot();
  } catch (e) {
    faviconCache.delete(origin);
  }
}

async function requestFrameReports() {
  const tabs = await chrome.tabs.query({});
  for (const t of tabs) sendCmd(t.id, { action: 'report' });
}

function sendCmd(tabId, cmd) {
  chrome.tabs.sendMessage(tabId, { type: 'cmd', ...cmd }).catch(() => {});
}

function applyTabMute(tabId) {
  const muted = !!appMuted.get(tabId) || softPaused.has(tabId);
  chrome.tabs.update(tabId, { muted }).catch(() => {});
}

async function togglePlay(tabId) {
  const frames = frameStates.get(tabId);
  let twitchLive = false;
  let playerPlaying = false;
  if (frames) for (const s of frames.values()) {
    if (s.twitchLive) twitchLive = true;
    if (s.playing) playerPlaying = true;
  }
  if (twitchLive && (playerPlaying || softPaused.has(tabId))) {
    if (softPaused.has(tabId)) softPaused.delete(tabId); else softPaused.add(tabId);
    if (!appMuted.has(tabId)) {
      const tab = await chrome.tabs.get(tabId).catch(() => null);
      appMuted.set(tabId, softPaused.has(tabId) ? !!(tab && tab.mutedInfo && tab.mutedInfo.muted) : false);
    }
    applyTabMute(tabId);
    scheduleSnapshot(0);
    return;
  }
  sendCmd(tabId, { action: 'togglePlay' });
}

function onAppMessage(msg) {
  if (!msg || typeof msg.type !== 'string') return;
  switch (msg.type) {
    case 'appStatus':
      appConnected = !!msg.connected;
      if (appConnected) { requestFrameReports(); scheduleSnapshot(0); }
      break;
    case 'requestSnapshot':
      appConnected = true;
      scheduleSnapshot(0);
      break;
    case 'setMute':
      appMuted.set(msg.tabId, !!msg.muted);
      applyTabMute(msg.tabId);
      break;
    case 'setVolume':
      sendCmd(msg.tabId, { action: 'setVolume', value: msg.value, position: msg.position });
      break;
    case 'togglePlay':
      togglePlay(msg.tabId);
      break;
    case 'jumpLive':
      sendCmd(msg.tabId, { action: 'jumpLive' });
      break;
    case 'setSpeed':
      sendCmd(msg.tabId, { action: 'setSpeed', rate: msg.rate });
      break;
    case 'seekBy':
      sendCmd(msg.tabId, { action: 'seekBy', seconds: msg.seconds });
      break;
    case 'focus':
      chrome.tabs.update(msg.tabId, { active: true }).catch(() => {});
      if (typeof msg.windowId === 'number' && msg.windowId >= 0) {
        chrome.windows.update(msg.windowId, { focused: true }).catch(() => {});
      }
      break;
  }
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || msg.type !== 'frameState' || !sender.tab) return;
  const tabId = sender.tab.id;
  let frames = frameStates.get(tabId);
  if (!frames) { frames = new Map(); frameStates.set(tabId, frames); }
  frames.set(sender.frameId || 0, msg.state);
  scheduleSnapshot();
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === 'loading' && changeInfo.url) {
    frameStates.delete(tabId);
    if (softPaused.delete(tabId)) applyTabMute(tabId);
  }
  scheduleSnapshot();
});
chrome.tabs.onRemoved.addListener((tabId) => {
  frameStates.delete(tabId);
  softPaused.delete(tabId);
  appMuted.delete(tabId);
  scheduleSnapshot();
});
chrome.tabs.onCreated.addListener(() => scheduleSnapshot());
chrome.tabs.onReplaced.addListener((added, removed) => { frameStates.delete(removed); scheduleSnapshot(); });

// Inject into tabs that were already open when the extension was installed or reloaded.
async function injectExisting() {
  const tabs = await chrome.tabs.query({});
  for (const t of tabs) {
    if (!t.url || !/^https?:/.test(t.url)) continue;
    chrome.scripting.executeScript({ target: { tabId: t.id, allFrames: true }, files: ['main-world.js'], world: 'MAIN' }).catch(() => {});
    chrome.scripting.executeScript({ target: { tabId: t.id, allFrames: true }, files: ['isolated.js'] }).catch(() => {});
  }
}
chrome.runtime.onInstalled.addListener(injectExisting);

// Auto-update: the app rewrites this folder on every launch. When build.json changes,
// release soft-paused tabs and reload so the new code runs without a manual reload.
async function checkForUpdate() {
  try {
    const res = await fetch(chrome.runtime.getURL('build.json'), { cache: 'no-store' });
    const info = await res.json();
    if (info && info.build && info.build !== BUILD) {
      for (const tabId of softPaused) {
        softPaused.delete(tabId);
        applyTabMute(tabId);
      }
      setTimeout(() => chrome.runtime.reload(), 300);
    }
  } catch (e) { /* no build.json: development copy */ }
}
setInterval(checkForUpdate, 5000);

// Heartbeat so play state and volumes stay fresh even without events.
setInterval(() => scheduleSnapshot(), 2000);

connect();
