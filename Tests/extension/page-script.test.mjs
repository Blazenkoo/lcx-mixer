// Runs the extension's page scripts in a pretend page, to catch start-up and take-over errors
// before they reach a browser. Run with: node --test Tests/extension/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makePage, makeButton, extension, pageScripts } from './fake-page.mjs';

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

test('after a take-over the new build uses its own site file', () => {
  const button = makeButton({ 'data-a-player-state': 'paused' });
  const page = makePage({
    host: 'www.twitch.tv', pathname: '/somechannel',
    elements: { 'button[data-a-target="player-play-pause-button"]': button },
  });
  page.addVideo();
  page.load('OLD');
  page.load('NEW');
  const s = page.state('NEW');
  assert.equal(s.twitchLive, true);
  assert.equal(s.playing, false, "Twitch's own button says paused");
  assert.deepEqual(page.errors(), []);
});

test('every page script carries the build ID', () => {
  for (const file of [...pageScripts, 'isolated.js', 'background.js']) {
    const source = fs.readFileSync(path.join(extension, file), 'utf8');
    assert.ok(source.includes("'__BUILD_ID__'"), file);
  }
});

test('the background worker re-injects exactly the manifest\'s page scripts', () => {
  const source = fs.readFileSync(path.join(extension, 'background.js'), 'utf8');
  assert.match(source, /const PAGE_SCRIPTS = chrome\.runtime\.getManifest\(\)/);
  assert.doesNotMatch(source, /files: \['main-world\.js'\]/);
});
