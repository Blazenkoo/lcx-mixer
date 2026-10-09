// Twitch: its own play button and volume slider. Live streams are "paused" by the background
// worker silencing the tab, so the stream stays live. Loaded before main-world.js.
(() => {
  const BUILD = '__BUILD_ID__';
  const sites = (window.__lcxMixerSites = window.__lcxMixerSites || {});
  (sites[BUILD] = sites[BUILD] || {}).twitch = (host, page) => {
    if (!/(^|\.)twitch\.tv$/.test(host)) return null;

    const isLive = () => !/\/(videos|clip)\//.test(location.pathname);

    function button() {
      return document.querySelector('button[data-a-target="player-play-pause-button"]');
    }

    // Its player volume slider. If Twitch renames it, volume still works through the video element.
    function volumeInput() {
      return document.querySelector('input[data-a-target="player-volume-slider"]') ||
        document.querySelector('[data-a-target="player-volume-slider"] input[type="range"]') ||
        document.querySelector('.video-player input[type="range"][aria-label*="olume" i]');
    }

    return {
      // Only Twitch: the background worker silences live streams instead of pausing them.
      isLiveStream: isLive,
      isPlaying() {
        const btn = button();
        const state = btn && btn.getAttribute('data-a-player-state');
        if (state === 'playing') return true;
        if (state === 'paused') return false;
        return undefined;
      },
      volume() {
        const input = volumeInput();
        const v = input && page.rangeValue(input);
        return v !== null && v !== undefined ? v : undefined;
      },
      // Moves Twitch's own slider; the media elements are set too (so this returns false).
      setVolume(v) {
        const input = volumeInput();
        if (input) { try { page.setRange(input, v); } catch (e) { /* fall through to the element */ } }
        return false;
      },
      // Only runs when the player itself is paused, e.g. by Twitch's own button.
      togglePlay() {
        const btn = button();
        if (!btn) return false;
        btn.click();
        return true;
      },
      canSpeed: () => (isLive() ? false : undefined),
      canSeek: () => (isLive() ? false : undefined),
      jumpLive() {
        const live = document.querySelector('[data-a-target="player-seekbar-live-button"], button[aria-label*="live" i][data-a-target]');
        if (!live) return false;
        live.click();
        return true;
      },
    };
  };
})();
