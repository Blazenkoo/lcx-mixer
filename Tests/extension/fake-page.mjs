// A pretend page for running the extension's page scripts outside a browser: fake media elements,
// inputs and buttons, a console that records, and no real timers.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const extension = path.join(root, 'Extension');
export const manifest = JSON.parse(fs.readFileSync(path.join(extension, 'manifest.json'), 'utf8'));
// The scripts that run in the page's own world, in the order the browser loads them.
export const pageScripts = manifest.content_scripts.find((c) => c.world === 'MAIN').js;

class Target {
  #listeners = new Map();
  /** Every event this element was sent, by type, for checks. */
  received = [];
  addEventListener(type, fn) {
    if (!this.#listeners.has(type)) this.#listeners.set(type, []);
    this.#listeners.get(type).push(fn);
  }
  removeEventListener(type, fn) {
    const list = this.#listeners.get(type) || [];
    const i = list.indexOf(fn);
    if (i >= 0) list.splice(i, 1);
  }
  dispatchEvent(event) {
    if (!event.target) event.target = this;
    this.received.push(event.type);
    for (const fn of [...(this.#listeners.get(event.type) || [])]) fn.call(this, event);
    return true;
  }
}

/**
 * A page at `host` and `pathname`. `elements` maps the CSS selectors the scripts ask
 * document.querySelector for to fake elements; `byId` does the same for getElementById.
 */
export function makePage({ host = 'www.example.com', pathname = '/', elements = {}, byId = {} } = {}) {
  const logs = [];
  class FakeEvent {
    constructor(type, init = {}) { this.type = type; this.detail = init.detail; this.target = null; }
  }
  class HTMLMediaElement extends Target {
    constructor() {
      super();
      Object.assign(this, {
        paused: true, ended: false, isConnected: true, volume: 1, playbackRate: 1,
        duration: 100, currentTime: 0, readyState: 4,
      });
    }
    play() { this.paused = false; return Promise.resolve(); }
    pause() { this.paused = true; }
  }
  class HTMLInputElement extends Target {}
  Object.defineProperty(HTMLInputElement.prototype, 'value', {
    get() { return this._value ?? ''; }, set(v) { this._value = String(v); }, configurable: true,
  });

  const players = [];
  const document = new Target();
  document.readyState = 'complete';
  document.querySelectorAll = (q) => (q.includes('video') ? players : []);
  document.querySelector = (q) => elements[q] ?? null;
  document.getElementById = (id) => byId[id] ?? null;

  const page = {
    document,
    location: { hostname: host, pathname },
    HTMLMediaElement, HTMLInputElement, CustomEvent: FakeEvent, Event: FakeEvent, MouseEvent: FakeEvent,
    console: {
      debug: (...a) => logs.push(a.map(String).join(' ')),
      error: (...a) => logs.push('ERROR ' + a.map(String).join(' ')),
      log() {}, info() {}, warn() {},
    },
    setInterval: () => 1, clearInterval() {}, setTimeout: () => 1, clearTimeout() {},
  };
  page.window = page;
  page.top = page;
  const context = vm.createContext(page);

  return {
    logs,
    errors: () => logs.filter((l) => l.startsWith('ERROR')),
    /** A video element already in the page, playing unless told otherwise. */
    addVideo({ playing = true } = {}) {
      const el = new HTMLMediaElement();
      el.paused = !playing;
      players.push(el);
      return el;
    },
    /** A site's range slider (volume or progress). Values are strings, as in a browser. */
    input({ min = '0', max = '1', value = '0' } = {}) {
      const el = new HTMLInputElement();
      Object.assign(el, { min, max });
      el.value = value;
      return el;
    },
    /** An audio element the site never attaches to the page (how Spotify plays). */
    detachedAudio() {
      const el = new HTMLMediaElement();
      el.isConnected = false;
      return el;
    },
    /** Loads the page scripts as one build of the extension. */
    load(build) {
      for (const file of pageScripts) {
        const source = fs.readFileSync(path.join(extension, file), 'utf8').replaceAll('__BUILD_ID__', build);
        vm.runInContext(source, context, { filename: file });
      }
    },
    /** Every state report a build sends from now on. */
    states(build) {
      const seen = [];
      document.addEventListener('lcxmixer:state:' + build, (e) => seen.push(JSON.parse(e.detail)));
      return seen;
    },
    command(build, message) {
      document.dispatchEvent(new FakeEvent('lcxmixer:cmd:' + build, { detail: JSON.stringify(message) }));
    },
    /** Asks a build for its state right now and returns it. */
    state(build) {
      const seen = this.states(build);
      this.command(build, { action: 'report' });
      return seen.at(-1);
    },
  };
}

/** A button that counts clicks and can carry attributes. */
export function makeButton(attributes = {}) {
  return {
    clicks: 0,
    attributes,
    click() { this.clicks += 1; },
    getAttribute(name) { return this.attributes[name] ?? null; },
  };
}
