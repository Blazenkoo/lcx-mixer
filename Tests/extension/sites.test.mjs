// What the page scripts do on each supported site, with fake versions of the site's own controls.
// Run with: node --test Tests/extension/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makePage, makeButton } from './fake-page.mjs';

test('any page: the playing media element is the player', () => {
  const page = makePage();
  const video = page.addVideo();
  page.load('A');
  let s = page.state('A');
  assert.equal(s.hasMedia, true);
  assert.equal(s.volumeIsPosition, false);
  assert.equal(s.canSpeed, true);
  assert.equal(s.canSeek, true);

  page.command('A', { action: 'setVolume', value: 0.4 });
  assert.equal(video.volume, 0.4);
  page.command('A', { action: 'setSpeed', rate: 1.5 });
  assert.equal(video.playbackRate, 1.5);
  page.command('A', { action: 'seekBy', seconds: 10 });
  assert.equal(video.currentTime, 10);
  page.command('A', { action: 'togglePlay' });
  assert.equal(video.paused, true);
  s = page.state('A');
  assert.equal(s.playing, false);
  assert.deepEqual(page.errors(), []);
});

test('YouTube: its player API drives volume, play, speed and seeking', () => {
  const yt = {
    volume: 40, playerState: 1, rate: 1, time: 100, live: false,
    setVolume(v) { this.volume = v; },
    getVolume() { return this.volume; },
    getPlayerState() { return this.playerState; },
    pauseVideo() { this.playerState = 2; },
    playVideo() { this.playerState = 1; },
    getPlaybackRate() { return this.rate; },
    setPlaybackRate(r) { this.rate = r; },
    getCurrentTime() { return this.time; },
    seekTo(t) { this.time = t; },
    getVideoData() { return { isLive: this.live }; },
  };
  const page = makePage({ host: 'www.youtube.com', pathname: '/watch', byId: { movie_player: yt } });
  page.load('A');
  let s = page.state('A');
  assert.equal(s.hasMedia, true, 'the player API counts even before a video element is seen');
  assert.equal(s.playing, true);
  assert.equal(s.volume, 0.4);
  assert.equal(s.canSpeed, true);
  assert.equal(s.canSeek, true);

  page.command('A', { action: 'setVolume', value: 0.25 });
  assert.equal(yt.volume, 25);
  page.command('A', { action: 'togglePlay' });
  assert.equal(yt.playerState, 2);
  page.command('A', { action: 'setSpeed', rate: 1.5 });
  assert.equal(yt.rate, 1.5);
  page.command('A', { action: 'seekBy', seconds: -15 });
  assert.equal(yt.time, 85);

  yt.live = true;
  s = page.state('A');
  assert.equal(s.canSpeed, false, 'no speed on live streams');
  assert.deepEqual(page.errors(), []);
});

test('Spotify: the slider position is the volume, and its own buttons are used', () => {
  const holder = {};
  const playButton = makeButton();
  const volumeBar = { querySelector: (q) => (q === 'input[type="range"]' ? holder.volume : null) };
  const page = makePage({
    host: 'open.spotify.com',
    elements: {
      '[data-testid="volume-bar"]': volumeBar,
      '[data-testid="control-button-playpause"]': playButton,
    },
  });
  holder.volume = page.input({ min: '0', max: '1', value: '0.5' });
  page.load('A');
  const audio = page.detachedAudio();
  audio.play(); // Spotify plays through an element it never attaches
  const s = page.state('A');
  assert.equal(s.hasMedia, true);
  assert.equal(s.volumeIsPosition, true);
  assert.equal(s.volume, 0.5);
  assert.equal(s.canSpeed, false);
  assert.equal(s.canSeek, false, 'no progress bar on this page');

  page.command('A', { action: 'setVolume', value: 0.09, position: 0.3 });
  assert.equal(holder.volume.value, '0.3');
  assert.deepEqual(holder.volume.received, ['input', 'change']);
  assert.equal(audio.volume, 1, 'never given a raw element volume');

  page.command('A', { action: 'togglePlay' });
  assert.equal(playButton.clicks, 1);
  assert.deepEqual(page.errors(), []);
});

test('Spotify: seeking moves the progress slider', () => {
  const holder = {};
  const spotify = makePage({
    host: 'open.spotify.com',
    elements: { get '[data-testid="playback-progressbar"] input[type="range"]'() { return holder.progress; } },
  });
  holder.progress = spotify.input({ min: '0', max: '200000', value: '10000' });
  spotify.load('A');
  spotify.detachedAudio().play();
  assert.equal(spotify.state('A').canSeek, true);
  spotify.command('A', { action: 'seekBy', seconds: 5 });
  assert.equal(holder.progress.value, '15000');
  assert.deepEqual(spotify.errors(), []);
});

test('Twitch: its own play button and volume slider are used; live streams can jump to live', () => {
  const holder = {};
  const playButton = makeButton({ 'data-a-player-state': 'playing' });
  const liveButton = makeButton();
  const page = makePage({
    host: 'www.twitch.tv',
    pathname: '/somechannel',
    elements: {
      'button[data-a-target="player-play-pause-button"]': playButton,
      get 'input[data-a-target="player-volume-slider"]'() { return holder.volume; },
      '[data-a-target="player-seekbar-live-button"], button[aria-label*="live" i][data-a-target]': liveButton,
    },
  });
  holder.volume = page.input({ min: '0', max: '1', value: '0.8' });
  const video = page.addVideo();
  page.load('A');
  let s = page.state('A');
  assert.equal(s.playing, true);
  assert.equal(s.volume, 0.8);
  assert.equal(s.twitchLive, true);
  assert.equal(s.canSpeed, false);
  assert.equal(s.canSeek, false);

  playButton.attributes['data-a-player-state'] = 'paused';
  assert.equal(page.state('A').playing, false, 'the button wins over the video element');

  page.command('A', { action: 'setVolume', value: 0.3 });
  assert.equal(holder.volume.value, '0.3');
  assert.equal(video.volume, 0.3, 'the element follows too');

  page.command('A', { action: 'togglePlay' });
  assert.equal(playButton.clicks, 1);
  page.command('A', { action: 'jumpLive' });
  assert.equal(liveButton.clicks, 1);
  assert.deepEqual(page.errors(), []);
});

test('Twitch recordings can change speed and seek', () => {
  const page = makePage({ host: 'www.twitch.tv', pathname: '/videos/123' });
  page.addVideo();
  page.load('A');
  const s = page.state('A');
  assert.equal(s.twitchLive, false);
  assert.equal(s.canSpeed, true);
  assert.equal(s.canSeek, true);
  assert.deepEqual(page.errors(), []);
});
