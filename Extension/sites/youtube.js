// YouTube (and YouTube Music): the page's own player API (#movie_player) drives volume,
// play/pause, speed and seeking. Loaded before main-world.js, which asks every site in turn.
(() => {
  const BUILD = '__BUILD_ID__';
  const sites = (window.__lcxMixerSites = window.__lcxMixerSites || {});
  (sites[BUILD] = sites[BUILD] || {}).youtube = (host) => {
    if (!/(^|\.)youtube(-nocookie)?\.com$/.test(host)) return null;

    function player() {
      const p = document.getElementById('movie_player');
      return p && typeof p.setVolume === 'function' && typeof p.getVolume === 'function' ? p : null;
    }

    function isLive() {
      const yt = player();
      try { return !!(yt && yt.getVideoData && yt.getVideoData().isLive); } catch (e) { return false; }
    }

    return {
      // The player counts as media even before a video element shows up.
      hasPlayer: () => !!player(),
      isPlaying() {
        const yt = player();
        if (yt && typeof yt.getPlayerState === 'function') return yt.getPlayerState() === 1;
        return undefined;
      },
      volume() {
        const yt = player();
        return yt ? yt.getVolume() / 100 : undefined;
      },
      setVolume(v) {
        const yt = player();
        if (!yt) return false;
        yt.setVolume(Math.round(v * 100));
        return true;
      },
      togglePlay() {
        const yt = player();
        if (!yt || typeof yt.getPlayerState !== 'function') return false;
        if (yt.getPlayerState() === 1) yt.pauseVideo(); else yt.playVideo();
        return true;
      },
      canSpeed() {
        if (isLive()) return false;
        return player() ? true : undefined;
      },
      canSeek: () => (player() ? true : undefined),
      speed() {
        const yt = player();
        return yt && typeof yt.getPlaybackRate === 'function' ? yt.getPlaybackRate() : undefined;
      },
      setSpeed(rate) {
        const yt = player();
        if (!yt || typeof yt.setPlaybackRate !== 'function') return false;
        yt.setPlaybackRate(rate);
        return true;
      },
      seekBy(seconds) {
        const yt = player();
        if (!yt || typeof yt.seekTo !== 'function') return false;
        yt.seekTo(Math.max(0, yt.getCurrentTime() + seconds), true);
        return true;
      },
    };
  };
})();
