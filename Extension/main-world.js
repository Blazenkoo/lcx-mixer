// Runs in the page's own JavaScript world so it can reach site players (YouTube API,
// Spotify's detached audio element). Talks to isolated.js through DOM events with string payloads.
// What's special about a site lives in sites/<site>.js, loaded just before this file; this file
// works with any page's media elements and asks the site's file first where it has a say.
(() => {
  // Each build replaces __BUILD_ID__; a newer copy shuts the older one down and takes over its media list.
  const BUILD = '__BUILD_ID__';
  if (window.__lcxMixerInstalled === BUILD) return;
  if (window.__lcxMixerInstalled) document.dispatchEvent(new CustomEvent('lcxmixer:shutdown'));
  window.__lcxMixerInstalled = BUILD;
  let stopped = false;
  // Event names carry the build, so copies left in a tab by older builds never hear new commands.
  const CMD_EVENT = 'lcxmixer:cmd:' + BUILD;
  const STATE_EVENT = 'lcxmixer:state:' + BUILD;
  const handed = Array.isArray(window.__lcxMixerMedia) ? window.__lcxMixerMedia : [];

  const media = new Set();
  let lastPlayed = null;
  let desiredVolume = null;   // last volume the app set
  let applyingUntil = 0;      // ignore volumechange events we caused
  let reapplyUntil = 0;       // window after a track change where a site reset is undone

  const now = () => Date.now();

  // This page's site file (sites/*.js), if it has one. Where a site method returns undefined or
  // false, it has nothing special to do and the general code below takes over.
  const site = findSite();

  function findSite() {
    const helpers = {
      setRange: (input, v) => setRange(input, v),
      rangeValue: (input) => rangeValue(input),
      setValue: (input, v) => nativeValueSetter.call(input, v),
      pointer: (type, target, x, y) => pointer(type, target, x, y),
      report: () => report(),
    };
    const makers = Object.values((window.__lcxMixerSites || {})[BUILD] || {});
    for (const make of makers) {
      try {
        const found = make(location.hostname, helpers);
        if (found) return found;
      } catch (e) {
        console.error('[LCX Mixer] site script failed', BUILD, e);
      }
    }
    return {};
  }

  function track(el) {
    if (stopped || !el || media.has(el)) return;
    media.add(el);
    const onPlay = () => { if (stopped) return; lastPlayed = el; report(); };
    el.addEventListener('play', onPlay);
    el.addEventListener('playing', onPlay);
    el.addEventListener('pause', report);
    el.addEventListener('ended', report);
    el.addEventListener('emptied', report);
    el.addEventListener('loadstart', () => {
      if (stopped) return;
      reapplyUntil = now() + 1500;
      if (desiredVolume !== null) applyVolume(desiredVolume);
    });
    el.addEventListener('volumechange', () => { if (!stopped) onVolumeChange(); });
    el.addEventListener('ratechange', () => { if (!stopped) report(); });
    el.addEventListener('durationchange', () => { if (!stopped) report(); });
    report();
  }

  // Catch media elements that are never attached to the page (Spotify) by hooking play().
  const originalPlay = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    try { if (!stopped) { track(this); lastPlayed = this; } } catch (e) { /* ignore */ }
    return originalPlay.apply(this, args);
  };

  const onDocPlay = (e) => {
    if (!stopped && e.target instanceof HTMLMediaElement) { track(e.target); lastPlayed = e.target; }
  };
  document.addEventListener('play', onDocPlay, true);

  const scan = () => document.querySelectorAll('video, audio').forEach(track);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', scan);
  // Players are found as they start (the 'play' event and the play() hook above), plus one scan at
  // start-up. The only timer is a light check-in for pages with a player, every 5 s, to catch
  // changes a site makes without an event; pages without one do nothing at all.
  const scanTimer = setInterval(() => { if (media.size || site.hasPlayer?.()) report(); }, 5000);

  function liveMedia() {
    return [...media].filter((el) => el.isConnected || !el.paused || el === lastPlayed);
  }

  function primary() {
    const list = liveMedia();
    const playing = list.find((el) => !el.paused && !el.ended);
    if (playing) return playing;
    if (lastPlayed && media.has(lastPlayed)) return lastPlayed;
    return list[0] || null;
  }

  // The site's own answer comes first; undefined means "nothing special here".
  function isPlaying() {
    const own = site.isPlaying?.();
    if (own !== undefined) return own;
    return liveMedia().some((el) => !el.paused && !el.ended && el.readyState > 1);
  }

  function currentVolume() {
    const own = site.volume?.();
    if (own !== undefined) return own;
    const el = primary();
    return el ? el.volume : null;
  }

  const nativeValueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;

  // Moves a site's own range slider (0…1 of its min…max) the way a user would, so the site's
  // state, its UI and the sound all follow.
  function setRange(input, v) {
    const min = parseFloat(input.min || '0');
    const max = parseFloat(input.max || '1');
    input.step = 'any';
    nativeValueSetter.call(input, String(min + v * (max - min)));
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function rangeValue(input) {
    const min = parseFloat(input.min || '0');
    const max = parseFloat(input.max || '1');
    const v = (parseFloat(input.value) - min) / ((max - min) || 1);
    return isFinite(v) ? Math.max(0, Math.min(1, v)) : null;
  }

  function pointer(type, target, x, y) {
    const init = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0, buttons: type.endsWith('up') ? 0 : 1 };
    target.dispatchEvent(new MouseEvent(type, init));
  }

  function applyVolume(v) {
    if (site.volumeIsPosition) return; // such a site gets fader positions instead (setPosition)
    applyingUntil = now() + 600;
    if (site.setVolume?.(v)) return; // the site's own player took it
    media.forEach((el) => { try { el.volume = v; } catch (e) { /* ignore */ } });
  }

  function onVolumeChange() {
    if (now() < applyingUntil) return;
    if (site.onPageVolumeChange?.()) return;
    if (desiredVolume !== null && now() < reapplyUntil) {
      // The site reset the volume on a track or quality change: put ours back.
      applyVolume(desiredVolume);
      return;
    }
    const v = currentVolume();
    if (v !== null) desiredVolume = v; // the user moved the site's own slider
    report();
  }

  function togglePlay() {
    if (site.togglePlay?.()) return;
    const playing = liveMedia().filter((el) => !el.paused && !el.ended);
    if (playing.length) {
      playing.forEach((el) => el.pause());
    } else {
      const el = primary();
      if (el) el.play().catch(() => {});
    }
  }

  // ---- Playback speed and seeking (knobs) ----

  const hasDuration = (el) => !!el && isFinite(el.duration) && el.duration > 0;

  function canSpeed() {
    const own = site.canSpeed?.();
    return own !== undefined ? own : hasDuration(primary());
  }

  function canSeek() {
    const own = site.canSeek?.();
    return own !== undefined ? own : hasDuration(primary());
  }

  function currentSpeed() {
    const own = site.speed?.();
    if (own !== undefined) return own;
    const el = primary();
    return el ? el.playbackRate : 1;
  }

  function setSpeed(rate) {
    if (site.setSpeed?.(rate)) return;
    liveMedia().forEach((el) => { try { el.playbackRate = rate; } catch (e) { /* ignore */ } });
  }

  function seekBy(seconds) {
    if (site.seekBy?.(seconds)) return;
    const el = primary();
    if (!el || !isFinite(el.duration)) return;
    el.currentTime = Math.max(0, Math.min(el.duration - 0.5, el.currentTime + seconds));
  }

  function jumpLive() {
    if (site.jumpLive?.()) return;
    const el = primary();
    if (!el) return;
    try {
      if (el.seekable && el.seekable.length) {
        el.currentTime = Math.max(0, el.seekable.end(el.seekable.length - 1) - 1);
      }
      if (el.paused) el.play().catch(() => {});
    } catch (e) { /* ignore */ }
  }

  let lastReport = '';
  function report() {
    const hasMedia = !!site.hasPlayer?.() || liveMedia().length > 0;
    const vol = hasMedia ? currentVolume() : null;
    const state = {
      hasMedia,
      playing: hasMedia && isPlaying(),
      volume: vol === null ? null : Math.round(vol * 1000) / 1000,
      canVolume: hasMedia,
      volumeIsPosition: !!site.volumeIsPosition,
      canSpeed: hasMedia && canSpeed(),
      canSeek: hasMedia && canSeek(),
      speed: hasMedia ? Math.round(currentSpeed() * 100) / 100 : 1,
      twitchLive: !!site.isLiveStream?.(),
    };
    const json = JSON.stringify(state);
    if (json === lastReport) return;
    lastReport = json;
    document.dispatchEvent(new CustomEvent(STATE_EVENT, { detail: json }));
  }

  const onCmd = (e) => {
    if (stopped) return;
    let msg;
    try { msg = JSON.parse(e.detail); } catch (err) { return; }
    switch (msg.action) {
      case 'report':
        lastReport = '';
        report();
        break;
      case 'setVolume':
        if (site.volumeIsPosition && typeof msg.position === 'number') {
          applyingUntil = now() + 600;
          site.setPosition(Math.max(0, Math.min(1, msg.position)));
          setTimeout(() => { lastReport = ''; report(); }, 350);
        } else if (typeof msg.value === 'number') {
          desiredVolume = Math.max(0, Math.min(1, msg.value));
          applyVolume(desiredVolume);
          setTimeout(() => { lastReport = ''; report(); }, 350);
        }
        break;
      case 'togglePlay':
        togglePlay();
        setTimeout(report, 300);
        break;
      case 'setSpeed':
        if (typeof msg.rate === 'number') {
          setSpeed(Math.max(0.25, Math.min(4, msg.rate)));
          setTimeout(() => { lastReport = ''; report(); }, 300);
        }
        break;
      case 'seekBy':
        if (typeof msg.seconds === 'number') seekBy(msg.seconds);
        break;
      case 'jumpLive':
        jumpLive();
        setTimeout(report, 300);
        break;
    }
  };
  document.addEventListener(CMD_EVENT, onCmd);

  document.addEventListener('lcxmixer:shutdown', function onShutdown() {
    stopped = true;
    window.__lcxMixerMedia = [...media];
    if (window.top === window) console.debug('[LCX Mixer] page script', BUILD, `handing over ${media.size} player(s)`);
    clearInterval(scanTimer);
    document.removeEventListener(CMD_EVENT, onCmd);
    document.removeEventListener('play', onDocPlay, true);
    document.removeEventListener('lcxmixer:shutdown', onShutdown);
  });

  // Start-up work runs last, once every declaration above exists: tracking a player sends a
  // report, which needs all of them. (Doing this earlier crashed every take-over after an update.)
  try {
    handed.forEach((el) => track(el));
    if (document.readyState !== 'loading') scan();
    if (window.top === window) {
      // console.debug: some sites (Spotify) wrap the console and drop info-level messages.
      console.debug('[LCX Mixer] page script', BUILD, handed.length ? `took over ${handed.length} player(s)` : 'started fresh',
        { attached: handed.filter((el) => el.isConnected).length, playing: handed.filter((el) => !el.paused).length });
    }
  } catch (e) {
    console.error('[LCX Mixer] page script failed to start', BUILD, e);
  }
})();
