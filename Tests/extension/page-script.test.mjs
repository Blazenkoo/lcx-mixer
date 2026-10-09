// Runs the extension's page scripts in a pretend page, to catch start-up and take-over errors
// before they reach a browser. Run with: node --test Tests/extension/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const extension = path.join(root, 'Extension');
const manifest = JSON.parse(fs.readFileSync(path.join(extension, 'manifest.json'), 'utf8'));
// The scripts that run in the page's own world, in the order the browser loads them.
const pageScripts = manifest.content_scripts.find((c) => c.world === 'MAIN').js;

class Target {
  #listeners = new Map();
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
    for (const fn of [...(this.#listeners.get(event.type) || [])]) fn.call(this, event);
    return true;
  }
}

/** A page with no site players: just video and audio elements, a console and no real timers. */
function makePage({ host = 'www.example.com', pathname = '/' } = {}) {
  const logs = [];
  class FakeEvent {
    constructor(type, init = {}) { this.type = type; this.detail = init.detail; this.target = null; }
  }
  class HTMLMediaElement extends Target {
    constructor() {
      super();
      Object.assign(this, { paused: true, ended: false, isConnected: true, volume: 1, playbackRate: 1, duration: 100, readyState: 4 });
    }
    play() { this.paused = false; return Promise.resolve(); }
    pause() { this.paused = true; }
  }
  class HTMLInputElement {}
  Object.defineProperty(HTMLInputElement.prototype, 'value', {
    get() { return this._value ?? ''; }, set(v) { this._value = v; }, configurable: true,
  });

  const players = [];
  const document = new Target();
  document.readyState = 'complete';
  document.querySelectorAll = (q) => (q.includes('video') ? players : []);
  document.querySelector = () => null;
  document.getElementById = () => null;

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
  };
}

test('starts fresh and reports the playing video', () => {
  const page = makePage();
  page.addVideo();
  const states = page.states('A');
  page.load('A');
  assert.deepEqual(page.errors(), []);
  assert.ok(page.logs.some((l) => l.includes('started fresh')));
  assert.equal(states.at(-1).hasMedia, true);
  assert.equal(states.at(-1).playing, true);
  assert.equal(states.at(-1).volume, 1);
});

test('a page without players reports nothing', () => {
  const page = makePage();
  const states = page.states('A');
  page.load('A');
  assert.deepEqual(page.errors(), []);
  assert.deepEqual(states, []);
});

test('the same build loaded twice runs once', () => {
  const page = makePage();
  page.load('A');
  page.load('A');
  assert.equal(page.logs.filter((l) => l.includes('started fresh')).length, 1);
});

test('a new build takes over the old build\'s players, including detached ones', () => {
  const page = makePage();
  const video = page.addVideo();
  page.load('OLD');
  const audio = page.detachedAudio();
  audio.play(); // caught by the old build's play() hook

  const states = page.states('NEW');
  page.load('NEW');
  assert.deepEqual(page.errors(), []);
  assert.ok(page.logs.some((l) => l.includes('OLD handing over 2 player(s)')));
  assert.ok(page.logs.some((l) => l.includes('NEW took over 2 player(s)')));
  assert.equal(states.at(-1).hasMedia, true);

  page.command('OLD', { action: 'setVolume', value: 0.2 });
  assert.equal(video.volume, 1, 'the old build no longer listens');
  page.command('NEW', { action: 'setVolume', value: 0.2 });
  assert.equal(video.volume, 0.2);
  assert.equal(audio.volume, 0.2);
});

test('Twitch live streams are reported as live, recordings are not', () => {
  const live = makePage({ host: 'www.twitch.tv', pathname: '/somechannel' });
  live.addVideo();
  const liveStates = live.states('A');
  live.load('A');
  assert.equal(liveStates.at(-1).twitchLive, true);

  const recording = makePage({ host: 'www.twitch.tv', pathname: '/videos/123' });
  recording.addVideo();
  const recordingStates = recording.states('A');
  recording.load('A');
  assert.equal(recordingStates.at(-1).twitchLive, false);
  assert.deepEqual([...live.errors(), ...recording.errors()], []);
});
