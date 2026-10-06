// Moumusic bridge around the original AMLL lyric player (@applemusic-like-lyrics/core, AGPL-3.0).
// Swift pushes the lyric lines and clock samples; this page renders with AMLL's own DOM player and reports taps back.
import { LyricPlayer } from "@applemusic-like-lyrics/core";
import "@applemusic-like-lyrics/core/style.css";

window.__amllErrors = [];
window.addEventListener("error", (e) => (/ResizeObserver loop/.test(e.message || "") || window.__amllErrors.push(
  `${e.message} @${e.lineno}:${e.colno} ${(e.error && e.error.stack ? e.error.stack : "").slice(0, 160)}`)));
window.addEventListener("unhandledrejection", (e) => window.__amllErrors.push(`rejection: ${String(e.reason).slice(0, 160)}`));
const guarded = (label, fn) => (...args) => {
  try { return fn(...args); } catch (e) {
    window.__amllErrors.push(`${label}: ${e && e.message} ${(e && e.stack ? e.stack : "").slice(0, 200)}`);
  }
};
const post = (message) => {
  try { window.webkit.messageHandlers.amll.postMessage(message); } catch (_) {}
};

const root = document.getElementById("root");
const player = new LyricPlayer();
root.appendChild(player.getElement());
player.setAlignPosition(0.4);
// AMLL starts every line up to 600 ms before its timestamp (a visual lead). The app already leads the clock by its own
// calibrated amount, so the two stacked and every song's lyrics ran early: the timestamps are used as they are.
player.setOptimizeOptions({ tryAdvanceStartTime: false });

let lines = [];
// Clock: the last sample from Swift and the local time it arrived, extrapolated between samples.
let baseMs = 0;
let baseAt = performance.now();
let playing = false;
let rate = 1;
let last = performance.now();

function currentMs(now) {
  return playing ? baseMs + (now - baseAt) * rate : baseMs;
}

// Measured requestAnimationFrame rate (one second, a few seconds after start), reported once to the app.
let fpsFrames = 0;
let fpsStart = 0;
let fpsReported = false;
function measureFps(now) {
  if (fpsReported) return;
  if (!fpsStart) { if (now > 4000) fpsStart = now; return; }
  fpsFrames += 1;
  if (now - fpsStart >= 1000) {
    fpsReported = true;
    post({ type: "fps", fps: Math.round(fpsFrames * 1000 / (now - fpsStart)) });
  }
}

const frameBody = guarded("frame", (now) => {
  measureFps(now);
  const delta = now - last;
  last = now;
  player.setCurrentTime(currentMs(now));
  player.update(delta);
});
function frame(now) {
  frameBody(now);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

player.addEventListener("line-click", (event) => {
  const line = lines[event.lineIndex];
  if (line) post({ type: "seek", time: line.startTime });
});

window.AMLLBridge = {
  /** `payload`: JSON array of AMLL LyricLine objects; `timeMs`: where the song is now. */
  load(payload, timeMs) {
    lines = JSON.parse(payload);
    baseMs = timeMs;
    baseAt = performance.now();
    player.setLyricLines(lines, timeMs);
    player.setCurrentTime(timeMs, true);
    player.update(0);
  },
  /** A clock sample: song time in ms (lyric offset already added), whether it is playing, and the rate. */
  sync(timeMs, isPlaying, playbackRate) {
    const now = performance.now();
    const predicted = currentMs(now);
    const jumped = Math.abs(timeMs - predicted) > 600;
    if (isPlaying !== playing) {
      playing = isPlaying;
      if (isPlaying) player.resume(); else player.pause();
    }
    baseMs = timeMs;
    baseAt = now;
    rate = playbackRate || 1;
    if (jumped) player.setCurrentTime(timeMs, true);
  },
  setFontSize(px) {
    const element = player.getElement();
    element.style.setProperty("--amll-lp-font-size", `${px}px`);
    element.style.fontSize = `${px}px`;
    // Same side margins as the standard lyric column (24pt), so a line holds as many characters as there.
    element.style.setProperty("--lyric-line-padding-x", "24px");
  },
  setBlur(enabled) { player.setEnableBlur(enabled); },
  setSpring(enabled) { player.setEnableSpring(enabled); },
};

for (const key of Object.keys(window.AMLLBridge)) { window.AMLLBridge[key] = guarded("bridge." + key, window.AMLLBridge[key]); }
post({ type: "ready" });
