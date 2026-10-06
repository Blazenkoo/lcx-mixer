// Runs in the page's own JavaScript world so it can reach site players (YouTube API,
// Spotify's detached audio element). Talks to isolated.js through DOM events with string payloads.
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

  const host = location.hostname;
  const isYouTube = /(^|\.)youtube(-nocookie)?\.com$/.test(host);
  const isSpotify = /(^|\.)spotify\.com$/.test(host);
  const isTwitch = /(^|\.)twitch\.tv$/.test(host);
  const isTwitchLive = () => isTwitch && !/\/(videos|clip)\//.test(location.pathname);

  const media = new Set();
  let lastPlayed = null;
  let desiredVolume = null;   // last volume the app set
  let applyingUntil = 0;      // ignore volumechange events we caused
  let reapplyUntil = 0;       // window after a track change where a site reset is undone

  const now = () => Date.now();

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
  handed.forEach((el) => track(el));

  const scan = () => document.querySelectorAll('video, audio').forEach(track);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', scan);
  } else {
    scan();
  }
  const scanTimer = setInterval(() => { scan(); report(); }, 2000);

  function ytPlayer() {
    if (!isYouTube) return null;
    const p = document.getElementById('movie_player');
    return p && typeof p.setVolume === 'function' && typeof p.getVolume === 'function' ? p : null;
  }

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

  function isPlaying() {
    if (isTwitch) {
      const btn = twitchButton();
      const state = btn && btn.getAttribute('data-a-player-state');
      if (state === 'playing') return true;
      if (state === 'paused') return false;
    }
    const yt = ytPlayer();
    if (yt && typeof yt.getPlayerState === 'function') return yt.getPlayerState() === 1;
    return liveMedia().some((el) => !el.paused && !el.ended && el.readyState > 1);
  }

  function currentVolume() {
    if (isSpotify) return spotifySliderValue();
    const yt = ytPlayer();
    if (yt) return yt.getVolume() / 100;
    const el = primary();
    return el ? el.volume : null;
  }

  // Spotify: drive its own volume control so the page's UI and state follow the fader.
  // 1) the slider's hidden range input (React listens to its input/change events)
  // 2) fallback: pointer events on the visible bar
  function spotifyRangeInput() {
    const root = document.querySelector('[data-testid="volume-bar"]') ||
      document.querySelector('[aria-label*="olume" i] input[type="range"]')?.closest('div');
    if (!root) return null;
    return root.querySelector('input[type="range"]');
  }

  const nativeValueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;

  function setSpotifyRange(v) {
    const input = spotifyRangeInput();
    if (!input) return false;
    const min = parseFloat(input.min || '0');
    const max = parseFloat(input.max || '1');
    input.step = 'any';
    nativeValueSetter.call(input, String(min + v * (max - min)));
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  }

  function spotifyVolumeBar() {
    const root = document.querySelector('[data-testid="volume-bar"]');
    if (!root) return null;
    return root.querySelector('[data-testid="progress-bar"]') || null;
  }

  function pointer(type, target, x, y) {
    const init = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0, buttons: type.endsWith('up') ? 0 : 1 };
    target.dispatchEvent(new MouseEvent(type, init));
  }

  let spotifyMethodLogged = false;
  function setSpotifySlider(v) {
    let method = 'none';
    try {
      if (setSpotifyRange(v)) {
        method = 'range';
      } else {
        const bar = spotifyVolumeBar();
        const r = bar && bar.getBoundingClientRect();
        if (r && r.width > 4) {
          const x = r.left + Math.max(0.001, Math.min(0.999, v)) * r.width;
          const y = r.top + r.height / 2;
          pointer('mousedown', bar, x, y);
          pointer('mouseup', bar, x, y);
          pointer('click', bar, x, y);
          method = 'mouse';
        }
      }
    } catch (e) {
      console.debug('[LCX Mixer] Spotify volume failed', e);
    }
    if (!spotifyMethodLogged) {
      spotifyMethodLogged = true;
      console.debug('[LCX Mixer] Spotify volume method:', method);
    }
    return method !== 'none';
  }

  // Spotify applies its own curve from slider to loudness, so it gets the fader *position*
  // and is never given a raw element volume (that fought Spotify and caused stuttering).
  let desiredPosition = null;
  function applySpotify(position) {
    applyingUntil = now() + 600;
    desiredPosition = position;
    setSpotifySlider(position);
  }

  function spotifySliderValue() {
    const input = spotifyRangeInput();
    if (!input) return null;
    const min = parseFloat(input.min || '0');
    const max = parseFloat(input.max || '1');
    const v = (parseFloat(input.value) - min) / ((max - min) || 1);
    return isFinite(v) ? Math.max(0, Math.min(1, v)) : null;
  }

  function applyVolume(v) {
    if (isSpotify) return; // handled by applySpotify
    applyingUntil = now() + 600;
    const yt = ytPlayer();
    if (yt) {
      yt.setVolume(Math.round(v * 100));
      return;
    }
    media.forEach((el) => { try { el.volume = v; } catch (e) { /* ignore */ } });
  }

  function onVolumeChange() {
    if (now() < applyingUntil) return;
    if (isSpotify) { setTimeout(report, 50); return; } // Spotify keeps its volume across tracks itself
    if (desiredVolume !== null && now() < reapplyUntil) {
      // The site reset the volume on a track or quality change: put ours back.
      applyVolume(desiredVolume);
      return;
    }
    const v = currentVolume();
    if (v !== null) desiredVolume = v; // the user moved the site's own slider
    report();
  }

  function twitchButton() {
    return document.querySelector('button[data-a-target="player-play-pause-button"]');
  }

  function togglePlay() {
    if (isTwitch) {
      // Live streams are "paused" by the background worker (tab silenced, stream stays live).
      // This path only runs when the player itself is paused, e.g. by Twitch's own button.
      const btn = twitchButton();
      if (btn) { btn.click(); return; }
    }
    if (isSpotify) {
      const btn = document.querySelector('[data-testid="control-button-playpause"]');
      if (btn) { btn.click(); return; }
    }
    const yt = ytPlayer();
    if (yt && typeof yt.getPlayerState === 'function') {
      if (yt.getPlayerState() === 1) yt.pauseVideo(); else yt.playVideo();
      return;
    }
    const playing = liveMedia().filter((el) => !el.paused && !el.ended);
    if (playing.length) {
      playing.forEach((el) => el.pause());
    } else {
      const el = primary();
      if (el) el.play().catch(() => {});
    }
  }

  // ---- Playback speed and seeking (knobs) ----

  function spotifyProgressInput() {
    return document.querySelector('[data-testid="playback-progressbar"] input[type="range"]');
  }

  function isYouTubeLive() {
    const yt = ytPlayer();
    try { return !!(yt && yt.getVideoData && yt.getVideoData().isLive); } catch (e) { return false; }
  }

  function canSpeed() {
    if (isSpotify || isTwitchLive() || isYouTubeLive()) return false;
    if (ytPlayer()) return true;
    const el = primary();
    return !!el && isFinite(el.duration) && el.duration > 0;
  }

  function canSeek() {
    if (isTwitchLive()) return false;
    if (isSpotify) return !!spotifyProgressInput();
    if (ytPlayer()) return true;
    const el = primary();
    return !!el && isFinite(el.duration) && el.duration > 0;
  }

  function currentSpeed() {
    const yt = ytPlayer();
    if (yt && typeof yt.getPlaybackRate === 'function') return yt.getPlaybackRate();
    const el = primary();
    return el ? el.playbackRate : 1;
  }

  function setSpeed(rate) {
    const yt = ytPlayer();
    if (yt && typeof yt.setPlaybackRate === 'function') {
      yt.setPlaybackRate(rate);
      return;
    }
    liveMedia().forEach((el) => { try { el.playbackRate = rate; } catch (e) { /* ignore */ } });
  }

  function seekBy(seconds) {
    if (isSpotify) {
      const input = spotifyProgressInput();
      if (!input) return;
      const max = parseFloat(input.max || '0');
      const next = Math.max(0, Math.min(max - 1000, parseFloat(input.value || '0') + seconds * 1000));
      input.step = 'any';
      nativeValueSetter.call(input, String(next));
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
      return;
    }
    const yt = ytPlayer();
    if (yt && typeof yt.seekTo === 'function') {
      yt.seekTo(Math.max(0, yt.getCurrentTime() + seconds), true);
      return;
    }
    const el = primary();
    if (!el || !isFinite(el.duration)) return;
    el.currentTime = Math.max(0, Math.min(el.duration - 0.5, el.currentTime + seconds));
  }

  function jumpLive() {
    if (isTwitch) {
      const live = document.querySelector('[data-a-target="player-seekbar-live-button"], button[aria-label*="live" i][data-a-target]');
      if (live) { live.click(); return; }
    }
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
    const yt = ytPlayer();
    const hasMedia = !!yt || liveMedia().length > 0;
    const vol = hasMedia ? currentVolume() : null;
    const state = {
      hasMedia,
      playing: hasMedia && isPlaying(),
      volume: vol === null ? null : Math.round(vol * 1000) / 1000,
      canVolume: hasMedia,
      volumeIsPosition: isSpotify,
      canSpeed: hasMedia && canSpeed(),
      canSeek: hasMedia && canSeek(),
      speed: hasMedia ? Math.round(currentSpeed() * 100) / 100 : 1,
      twitchLive: isTwitchLive(),
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
        if (isSpotify && typeof msg.position === 'number') {
          applySpotify(Math.max(0, Math.min(1, msg.position)));
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
    clearInterval(scanTimer);
    document.removeEventListener(CMD_EVENT, onCmd);
    document.removeEventListener('play', onDocPlay, true);
    document.removeEventListener('lcxmixer:shutdown', onShutdown);
  });
})();
