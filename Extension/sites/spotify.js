// Spotify: it plays through an audio element it never attaches to the page, and applies its own
// curve from slider to loudness. So it gets the fader *position* and its own volume slider is
// moved; it's never given a raw element volume (that fought Spotify and caused stuttering).
// Loaded before main-world.js.
(() => {
  const BUILD = '__BUILD_ID__';
  const sites = (window.__lcxMixerSites = window.__lcxMixerSites || {});
  (sites[BUILD] = sites[BUILD] || {}).spotify = (host, page) => {
    if (!/(^|\.)spotify\.com$/.test(host)) return null;

    // 1) the slider's hidden range input (React listens to its input/change events)
    // 2) fallback: pointer events on the visible bar
    function rangeInput() {
      const root = document.querySelector('[data-testid="volume-bar"]') ||
        document.querySelector('[aria-label*="olume" i] input[type="range"]')?.closest('div');
      if (!root) return null;
      return root.querySelector('input[type="range"]');
    }

    function volumeBar() {
      const root = document.querySelector('[data-testid="volume-bar"]');
      if (!root) return null;
      return root.querySelector('[data-testid="progress-bar"]') || null;
    }

    function progressInput() {
      return document.querySelector('[data-testid="playback-progressbar"] input[type="range"]');
    }

    let methodLogged = false;
    function setSlider(v) {
      let method = 'none';
      try {
        const input = rangeInput();
        if (input) {
          page.setRange(input, v);
          method = 'range';
        } else {
          const bar = volumeBar();
          const r = bar && bar.getBoundingClientRect();
          if (r && r.width > 4) {
            const x = r.left + Math.max(0.001, Math.min(0.999, v)) * r.width;
            const y = r.top + r.height / 2;
            page.pointer('mousedown', bar, x, y);
            page.pointer('mouseup', bar, x, y);
            page.pointer('click', bar, x, y);
            method = 'mouse';
          }
        }
      } catch (e) {
        console.debug('[LCX Mixer] Spotify volume failed', e);
      }
      if (!methodLogged) {
        methodLogged = true;
        console.debug('[LCX Mixer] Spotify volume method:', method);
      }
      return method !== 'none';
    }

    return {
      volumeIsPosition: true,
      volume() {
        const input = rangeInput();
        return input ? page.rangeValue(input) : null;
      },
      setPosition: setSlider,
      // Spotify keeps its volume across tracks itself: just report what it shows now.
      onPageVolumeChange() {
        setTimeout(page.report, 50);
        return true;
      },
      togglePlay() {
        const btn = document.querySelector('[data-testid="control-button-playpause"]');
        if (!btn) return false;
        btn.click();
        return true;
      },
      canSpeed: () => false,
      canSeek: () => !!progressInput(),
      seekBy(seconds) {
        const input = progressInput();
        if (!input) return true;
        const max = parseFloat(input.max || '0');
        const next = Math.max(0, Math.min(max - 1000, parseFloat(input.value || '0') + seconds * 1000));
        input.step = 'any';
        page.setValue(input, String(next));
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      },
    };
  };
})();
