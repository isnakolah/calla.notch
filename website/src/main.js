import "./style.css";
import { createExplorer } from "./explorer.js";
import { currentTurn } from "./meeting.js";
import { storyState, nativeTimeline } from "./graph-data.js";
import { createAnalytics } from "./analytics.js";
import { createWatchProgress } from "./watch-progress.js";
const $ = (s) => document.querySelector(s);
const analytics = createAnalytics(),
  START = 0,
  END = 45,
  DURATION = END - START,
  watchProgress = createWatchProgress(DURATION);
const video = $("#call-video"),
  progress = $("#progress"),
  reduced = matchMedia("(prefers-reduced-motion:reduce)");
const format = (s) =>
  `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
let chapter = "meeting",
  brain = null,
  currentEvent = null,
  lastTurn = undefined,
  hasPlayed = false,
  raf = 0,
  explorer = null,
  exploring = false,
  savedPlayback = null,
  watchAt = null,
  resumeChapter = false,
  explorerRequest = 0;
document.body.dataset.chapter = chapter;
progress.min = START;
progress.max = END;
progress.disabled = true;
video.controls = false;
video.muted = true;
video.loop = false;
const safari =
  /Safari/.test(navigator.userAgent) &&
  !/Chrome|Chromium|Edg|Android/.test(navigator.userAgent);
let fallbackAttempt = false;
function selectNativeLayout(initial = false) {
  const time = video.currentTime || START,
    resume = initial || !video.paused;
  const stem = "notch-zen",
    alphaSupported = safari && video.canPlayType('video/mp4; codecs="hvc1"');
  fallbackAttempt = false;
  video.dataset.fallback = "false";
  video.addEventListener(
    "loadedmetadata",
    () => {
      video.currentTime = Math.max(START, Math.min(time, END - 0.01));
      const begin = () => {
        if (resume && chapter === "meeting" && !exploring && !document.hidden)
          video.play().catch(paused);
      };
      if (video.seeking)
        video.addEventListener("seeked", begin, { once: true });
      else begin();
      update();
    },
    { once: true },
  );
  video.poster = `/demo/${stem}-poster.png`;
  video.src = `/demo/${stem}.${alphaSupported ? "mov" : "webm"}`;
}

const phaseText = {
  listening: "A LITTLE CONTEXT",
  capture: "FROM THE CONVERSATION",
  understanding: "CALLA KEEPS THE THREAD",
  transfer: "A NEW MEMORY ARRIVES",
  forming: "A NEURON TAKES SHAPE",
  linking: "CONNECTIONS TAKE ROOT",
  connected: "YOUR WORK, CONNECTED",
};
function update() {
  const time = Math.max(START, Math.min(video.currentTime || START, END)),
    state = storyState(time);
  progress.value = time;
  progress.setAttribute(
    "aria-valuetext",
    `${format(time - START)} of ${format(DURATION)}`,
  );
  $("#clock").textContent = `${format(time - START)} / ${format(DURATION)}`;
  if (
    video.readyState >= 2 &&
    video.currentTime >= START &&
    video.hasAttribute("poster")
  )
    video.removeAttribute("poster");
  mirrorFull();
  animateCapture(state);
  if (chapter === "meeting") {
    $("#brain-kicker").textContent = phaseText[state.phase];
    if (currentEvent !== state.current) {
      $("#brain-explanation").textContent = state.current.text;
      currentEvent = state.current;
    }
  }
  const turn = currentTurn(nativeTimeline, time),
    source = turn?.source === "me" ? "You" : "Maya";
  if (turn !== lastTurn) {
    $("#speech-name").textContent = turn ? source : "Your weekly check-in";
    $("#speech-text").textContent =
      turn?.text ||
      "An ordinary conversation. The beginning of something connected.";
    lastTurn = turn;
  }
  $("#speech-stage").querySelector("div > span").textContent = video.paused
    ? "MEETING PAUSED"
    : "IS SPEAKING";
  $("#maya-tile").classList.toggle(
    "speaking",
    Boolean(turn && source === "Maya" && !video.paused),
  );
  $("#you-tile").classList.toggle(
    "speaking",
    Boolean(turn && source === "You" && !video.paused),
  );
  watchProgress.observe(time - START, !video.paused, video.seeking);
  for (const milestone of watchProgress.milestones())
    analytics.track(milestone);
  if (time >= END - 0.35 && watchProgress.complete())
    analytics.track("demo_complete");
}
function animateCapture(state) {
  const visible = chapter === "meeting" && !exploring,
    phase = state.phase,
    active =
      visible && !reduced.matches && ["capture", "transfer"].includes(phase);
  $("#capture-overlay").style.opacity = active ? "1" : "0";
  $("#notch-anchor").classList.toggle(
    "is-understanding",
    visible && ["understanding", "transfer"].includes(phase),
  );
  const stage =
    phase === "capture" || phase === "listening"
      ? "call"
      : phase === "understanding"
        ? "notch"
        : "brain";
  document
    .querySelectorAll("[data-flow]")
    .forEach((el) => el.classList.toggle("active", el.dataset.flow === stage));
  if (!active || !state.capture) return;
  const tile = $(
      state.capture.source === "me" ? "#you-tile" : "#maya-tile",
    ).getBoundingClientRect(),
    notch = $("#native-stage").getBoundingClientRect();
  const source = {
      x: tile.left + tile.width * 0.5,
      y: tile.top + tile.height * 0.5,
    },
    middle = { x: notch.left + notch.width * 0.5, y: notch.top + 22 };
  const brainRect = $("#brain").getBoundingClientRect(),
    end = brain?.focusPoint(state.capture.target) || {
      x: brainRect.left + brainRect.width * 0.5,
      y: brainRect.top + brainRect.height * 0.5,
    };
  const a = phase === "capture" ? source : middle,
    b = phase === "capture" ? middle : end,
    control =
      phase === "capture"
        ? { x: source.x, y: middle.y + 30 }
        : { x: end.x - 70, y: middle.y + 25 };
  const at = (t) => ({
    x: (1 - t) ** 2 * a.x + 2 * (1 - t) * t * control.x + t * t * b.x,
    y: (1 - t) ** 2 * a.y + 2 * (1 - t) * t * control.y + t * t * b.y,
  });
  const t = state.phaseProgress,
    p = at(t),
    tail = at(Math.max(0, t - 0.075));
  $("#capture-path").setAttribute(
    "d",
    `M${a.x},${a.y} Q${control.x},${control.y} ${b.x},${b.y}`,
  );
  for (const id of ["#capture-dot", "#capture-halo"]) {
    $(id).setAttribute("cx", p.x);
    $(id).setAttribute("cy", p.y);
  }
  $("#capture-tail").setAttribute("cx", tail.x);
  $("#capture-tail").setAttribute("cy", tail.y);
}
function frame() {
  update();
  if (!video.paused && !video.ended) raf = requestAnimationFrame(frame);
}
async function toggle() {
  analytics.track("demo_interact");
  if (!video.paused) {
    video.pause();
    return;
  }
  if (video.ended || video.currentTime >= END) video.currentTime = START;
  try {
    await video.play();
  } catch {
    $("#speech-text").textContent =
      "The sample couldn’t load. Please refresh and try again.";
  }
}
$("#play").addEventListener("click", toggle);
$("#hero-play").addEventListener("click", () => {
  $("#meeting-scene").scrollIntoView({
    behavior: reduced.matches ? "instant" : "smooth",
    block: "center",
  });
  if (video.paused) toggle();
});
video.addEventListener("play", () => {
  document.body.classList.add("meeting-started");
  hasPlayed = true;
  progress.disabled = false;
  analytics.track("demo_start");
  $("#play-label").textContent = "Pause";
  $("#play").setAttribute("aria-label", "Pause sample meeting");
  $("#play-icon").setAttribute("d", "M5 3h3v14H5zm7 0h3v14h-3z");
  lastTurn = undefined;
  cancelAnimationFrame(raf);
  frame();
});
function paused() {
  $("#play-label").textContent = video.ended ? "Replay" : "Play";
  $("#play").setAttribute(
    "aria-label",
    video.ended ? "Replay sample meeting" : "Play sample meeting",
  );
  $("#play-icon").setAttribute("d", "m6 3 11 7-11 7Z");
  lastTurn = undefined;
  cancelAnimationFrame(raf);
  update();
  brain?.update();
}
video.addEventListener("pause", paused);
video.addEventListener("ended", () => {
  if (watchProgress.complete()) analytics.track("demo_complete");
  if (chapter === "meeting" && !exploring && !document.hidden) {
    video.currentTime = START;
    watchProgress.resetPosition();
    video.play().catch(paused);
  } else paused();
});
video.addEventListener("seeking", () => watchProgress.resetPosition());
video.addEventListener("seeked", () => {
  update();
  brain?.update();
});
progress.addEventListener("input", () => {
  if (hasPlayed) {
    analytics.track("demo_interact");
    video.currentTime = Number(progress.value);
    update();
    brain?.update();
  }
});
$("#replay").addEventListener("click", () => {
  analytics.track("demo_interact");
  video.currentTime = START;
  watchProgress.resetPosition();
  update();
  video.play().catch(paused);
});
// The Zen recording is the only clock. Expansion never replaces its source.
const fullVideo = $("#call-video-full"),
  notch = $("#notch-anchor");
let expanded = false,
  fullReady = false,
  fullRequested = false,
  fullFallback = false,
  fullPlaying = false;
function mirrorFull() {
  if (!expanded) {
    fullVideo.pause();
    return;
  }
  if (
    fullVideo.readyState >= 1 &&
    Math.abs(fullVideo.currentTime - video.currentTime) > 0.18
  )
    fullVideo.currentTime = video.currentTime;
  if (video.paused || document.hidden || exploring) fullVideo.pause();
  else if (fullReady && fullVideo.paused && !fullPlaying) {
    fullPlaying = true;
    fullVideo
      .play()
      .catch(() => {})
      .finally(() => {
        fullPlaying = false;
      });
  }
}
function showNativeLayout() {
  fullVideo.hidden = !expanded || !fullReady;
  video.style.opacity = expanded && fullReady ? "0" : "1";
  $("#notch-loading").hidden = !expanded || fullReady;
  notch.classList.toggle("expanded", expanded);
  $("#notch-toggle").setAttribute("aria-expanded", String(expanded));
  $("#notch-toggle").setAttribute(
    "aria-label",
    expanded ? "Collapse Calla" : "Expand Calla",
  );
  $("#notch-toggle").innerHTML = expanded
    ? '<span>Collapse</span><b aria-hidden="true">↙</b>'
    : '<span>Expand Calla</span><b aria-hidden="true">↗</b>';
  mirrorFull();
}
fullVideo.addEventListener("loadedmetadata", () => {
  fullVideo.currentTime = video.currentTime;
});
fullVideo.addEventListener("loadeddata", () => {
  fullReady = true;
  showNativeLayout();
});
fullVideo.addEventListener("error", () => {
  if (!fullFallback) {
    fullFallback = true;
    fullVideo.src = "/demo/weekly-check-in-full.mp4";
  } else {
    expanded = false;
    fullReady = false;
    fullRequested = false;
    showNativeLayout();
    $("#notch-error").hidden = false;
  }
});
$("#notch-toggle").addEventListener("click", () => {
  expanded = !expanded;
  analytics.track("demo_interact");
  if (expanded && !fullRequested) {
    fullRequested = true;
    fullFallback = false;
    $("#notch-error").hidden = true;
    const alphaSupported =
      safari && fullVideo.canPlayType('video/mp4; codecs="hvc1"');
    fullVideo.src = `/demo/notch-full.${alphaSupported ? "mov" : "webm"}`;
    fullVideo.load();
  }
  showNativeLayout();
});
video.addEventListener("error", () => {
  if (!fallbackAttempt) {
    fallbackAttempt = true;
    video.src = "/demo/weekly-check-in-zen.mp4";
    video.dataset.fallback = "true";
  } else
    $("#speech-text").textContent =
      "The sample is unavailable. Please refresh and try again.";
});
const chapters = [...document.querySelectorAll("section[data-chapter]")],
  texts = {
    connected: [
      "WORK, CONNECTED",
      "A document adds the why. The next conversation starts with context.",
    ],
    company: [
      "ONE SHARED COMPANY BRAIN",
      "People. Projects. Decisions. Follow the thread between them.",
    ],
  };
function setChapter(next) {
  if (chapter === next) return;
  if (chapter === "meeting") resumeChapter = !video.paused;
  chapter = next;
  document.body.dataset.chapter = chapter;
  if (chapter !== "meeting") {
    video.pause();
    $("#brain-kicker").textContent = texts[chapter][0];
    $("#brain-explanation").textContent = texts[chapter][1];
    $("#capture-overlay").style.opacity = "0";
  } else {
    currentEvent = null;
    update();
    if (resumeChapter && !exploring) video.play().catch(paused);
  }
  document.querySelectorAll(".chapter-nav a").forEach((a) => {
    const active = a.hash === `#${chapter}`;
    a.classList.toggle("active", active);
    if (active) a.setAttribute("aria-current", "step");
    else a.removeAttribute("aria-current");
  });
  brain?.update();
}
let scrollPending = false;
function onScroll() {
  if (scrollPending || exploring) return;
  scrollPending = true;
  requestAnimationFrame(() => {
    const readingLine = innerHeight * 0.25,
      active =
        [...chapters]
          .reverse()
          .find((el) => el.getBoundingClientRect().top <= readingLine) ||
        chapters[0];
    setChapter(active.dataset.chapter);
    update();
    brain?.update();
    scrollPending = false;
  });
}
addEventListener("scroll", onScroll, { passive: true });
addEventListener("resize", () => {
  onScroll();
  update();
  brain?.update();
});
const chapterTimers = new Map();
const chapterObserver = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      clearTimeout(chapterTimers.get(entry.target));
      chapterTimers.delete(entry.target);
      if (
        entry.isIntersecting &&
        entry.intersectionRect.height >=
          Math.min(entry.boundingClientRect.height * 0.5, innerHeight * 0.5)
      ) {
        chapterTimers.set(
          entry.target,
          setTimeout(() => {
            chapterTimers.delete(entry.target);
            const rect = entry.target.getBoundingClientRect();
            const visible =
              Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0);
            if (visible >= Math.min(rect.height * 0.5, innerHeight * 0.5)) {
              analytics.track("chapter", entry.target.dataset.chapter);
            }
          }, 1000),
        );
      }
    }
  },
  { threshold: [0, 0.1, 0.25, 0.5, 0.75, 1] },
);
chapters.forEach((el) => chapterObserver.observe(el));
const graphDialog = $("#graph-dialog");
async function openExplorer(id) {
  if (exploring) return;
  const request = ++explorerRequest;
  exploring = true;
  savedPlayback = { time: video.currentTime, playing: !video.paused };
  video.pause();
  document.documentElement.classList.add("graph-open");
  graphDialog.showModal();
  $("#explorer-fallback").hidden = true;
  $("#explorer-labels").hidden = false;
  try {
    if (!graphDialog.open || request !== explorerRequest) return;
    explorer = createExplorer({
      selectedId: id,
      onWatch(at) {
        watchAt = at;
        graphDialog.close();
      },
    });
  } catch {
    $("#explorer-fallback").hidden = false;
    const fallback = $("#explorer-fallback");
    fallback.textContent =
      "The explorer couldn’t start. Reload the page to try again.";
    const retry = document.createElement("button");
    retry.className = "primary-button";
    retry.textContent = "Reload this page";
    retry.addEventListener("click", () => location.reload());
    fallback.append(retry);
  }
}
document
  .querySelectorAll("[data-explore]")
  .forEach((button) => button.addEventListener("click", () => openExplorer()));
$("#graph-close").addEventListener("click", () => graphDialog.close());
graphDialog.addEventListener("close", () => {
  explorerRequest++;
  explorer?.dispose();
  explorer = null;
  exploring = false;
  document.documentElement.classList.remove("graph-open");
  if (watchAt !== null) {
    const at = watchAt;
    watchAt = null;
    resumeChapter = false;
    setChapter("meeting");
    $("#meeting-scene").scrollIntoView({
      block: "center",
      behavior: "instant",
    });
    $("#play").focus({ preventScroll: true });
    video.pause();
    video.currentTime = at;
  } else if (savedPlayback) {
    video.currentTime = savedPlayback.time;
    if (savedPlayback.playing && chapter === "meeting" && !document.hidden)
      video.play().catch(paused);
  }
  brain?.update();
  update();
});
let resumeVisible = false;
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    resumeVisible = !video.paused;
    video.pause();
  } else if (
    (resumeVisible || !hasPlayed) &&
    chapter === "meeting" &&
    !document.querySelector("dialog[open]")
  ) {
    video.play().catch(paused);
    resumeVisible = false;
  }
});
$("#email").addEventListener("focus", () => analytics.track("cta_open"));
$(".inline-interests").addEventListener("toggle", () => {
  if ($(".inline-interests").open) analytics.track("cta_open");
});
document.querySelectorAll("[data-signup]").forEach((b) =>
  b.addEventListener("click", (event) => {
    event.preventDefault();
    $("#signup").scrollIntoView({
      behavior: reduced.matches ? "instant" : "smooth",
      block: "center",
    });
    $("#email").focus({ preventScroll: true });
  }),
);
$("#about-open").addEventListener("click", () => {
  video.pause();
  $("#about-dialog").showModal();
});
document
  .querySelectorAll("[data-close]")
  .forEach((b) =>
    b.addEventListener("click", () => b.closest("dialog").close()),
  );
$("#about-dialog").addEventListener("click", (e) => {
  if (e.target === e.currentTarget) {
    const r = e.currentTarget.getBoundingClientRect();
    if (
      e.clientX < r.left ||
      e.clientX > r.right ||
      e.clientY < r.top ||
      e.clientY > r.bottom
    )
      e.currentTarget.close();
  }
});
$("#signup").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  if (!form.reportValidity()) return;
  const button = form.querySelector("[type=submit]"),
    status = $("#signup-status");
  button.disabled = true;
  button.textContent = "Saving…";
  status.textContent = "";
  status.className = "signup-note";
  try {
    const response = await fetch("/api/waitlist", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        email: form.email.value.trim(),
        website: form.website.value,
        consent: "launch-notification-v1",
        interests: [...form.querySelectorAll("[name=interests]:checked")].map(
          (i) => i.value,
        ),
        ...analytics.context(),
      }),
      signal: AbortSignal.timeout(15000),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok || result.ok !== true)
      throw Error(
        result.error || "We couldn’t save your email. Please try again.",
      );
    status.textContent =
      "You’re on the list. We’ll let you know when Calla is ready.";
    status.classList.add("success");
    $(".inline-interests").open = false;
    button.textContent = "You’re on the list ✓";
    form.email.disabled = true;
    form
      .querySelectorAll("[name=interests]")
      .forEach((i) => (i.disabled = true));
  } catch (error) {
    status.textContent =
      error.name === "TimeoutError" || error instanceof TypeError
        ? "Couldn’t connect. Please try again in a moment."
        : error.message;
    status.classList.add("error");
    button.disabled = false;
    button.textContent = "Join the launch list ↗";
  }
});
import("./brain.js")
  .then(async ({ createBrain }) => {
    brain = await createBrain(
      $("#brain"),
      $("#brain-labels"),
      () => ({
        time: video.currentTime || START,
        playing: !video.paused && !video.ended,
        chapter,
        exploring,
      }),
      openExplorer,
    );
  })
  .catch(() => {
    $("#brain").dataset.renderer = "fallback";
    const fallback = $("#brain-fallback");
    fallback.hidden = false;
    const image = document.createElement("img");
    image.src = "/models/brain-neural-fallback.jpg";
    image.alt =
      "An anatomical brain with folded neural pathways connecting knowledge.";
    fallback.replaceChildren(image);
  });
function keyboardLayout() {
  if (!window.visualViewport) return;
  const inset = Math.max(
    0,
    innerHeight - visualViewport.height - visualViewport.offsetTop,
  );
  document.documentElement.style.setProperty("--keyboard-offset", `${inset}px`);
  document.body.classList.toggle("keyboard-open", inset > 120);
}
visualViewport?.addEventListener("resize", keyboardLayout);
visualViewport?.addEventListener("scroll", keyboardLayout);
selectNativeLayout(true);
onScroll();
update();
keyboardLayout();
