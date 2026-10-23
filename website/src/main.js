import "./style.css";
import { createAnalytics } from "./analytics.js";
import { createWatchProgress } from "./watch-progress.js";
import { createStage, LOOP } from "./stage.js";
const $ = (s) => document.querySelector(s);
const analytics = createAnalytics(),
  watchProgress = createWatchProgress(LOOP),
  reduced = matchMedia("(prefers-reduced-motion:reduce)");
let explorer = null,
  exploring = false,
  explorerRequest = 0,
  watchAt = null,
  resumeAfterDialog = false,
  started = false,
  lastTime = 0;

// The sample call. Muted autoplay counts as a demo start; milestones count
// time actually watched, so jumping ahead cannot inflate completion.
const playButton = $("#stage-play");
const stage = createStage($("#stage"), {
  onTick(time, playing) {
    if (playing && !started) {
      started = true;
      analytics.track("demo_start");
    }
    const wrapped = time < lastTime;
    if (wrapped) {
      if (watchProgress.complete()) analytics.track("demo_complete");
      watchProgress.resetPosition();
    }
    lastTime = time;
    watchProgress.observe(time, playing && !exploring, false);
    for (const milestone of watchProgress.milestones()) analytics.track(milestone);
    if (time >= LOOP - 0.35 && watchProgress.complete()) analytics.track("demo_complete");
  },
  onInteract: () => analytics.track("demo_interact"),
});
function syncPlayButton() {
  playButton.textContent = stage.playing ? "Pause" : "Play";
  playButton.setAttribute("aria-pressed", String(!stage.playing));
}
if (reduced.matches) {
  stage.seek(LOOP - 0.5);
  stage.pause();
}
syncPlayButton();
playButton.addEventListener("click", () => {
  analytics.track("demo_interact");
  if (stage.playing) stage.pause();
  else stage.play();
  syncPlayButton();
});
$("#stage-replay").addEventListener("click", () => {
  analytics.track("demo_interact");
  stage.seek(0);
  watchProgress.resetPosition();
  stage.play();
  syncPlayButton();
});

// Chapter views: half the section (or half the viewport) visible for a second.
const chapterTimers = new Map();
const chapterObserver = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      clearTimeout(chapterTimers.get(entry.target));
      chapterTimers.delete(entry.target);
      if (entry.isIntersecting && entry.intersectionRect.height >= Math.min(entry.boundingClientRect.height * 0.5, innerHeight * 0.5)) {
        chapterTimers.set(
          entry.target,
          setTimeout(() => {
            chapterTimers.delete(entry.target);
            const rect = entry.target.getBoundingClientRect(),
              visible = Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0);
            if (visible >= Math.min(rect.height * 0.5, innerHeight * 0.5)) analytics.track("chapter", entry.target.dataset.chapter);
          }, 1000),
        );
      }
    }
  },
  { threshold: [0, 0.1, 0.25, 0.5, 0.75, 1] },
);
document.querySelectorAll("section[data-chapter]").forEach((el) => chapterObserver.observe(el));

// Sticky call to action: once the call has been seen, out of the way of the signup.
const sticky = $("#sticky-cta");
let pastStage = false,
  atJoin = false;
const toggleSticky = () => sticky.classList.toggle("visible", pastStage && !atJoin);
new IntersectionObserver(([e]) => {
  pastStage = !e.isIntersecting && e.boundingClientRect.top < 0;
  toggleSticky();
}).observe($("#stage"));
new IntersectionObserver(([e]) => {
  atJoin = e.isIntersecting;
  toggleSticky();
}).observe($("#join"));

// Knowledge explorer.
const graphDialog = $("#graph-dialog");
// Three.js only loads when someone opens the explorer, keeping the page light.
const loadExplorer = () => import("./explorer.js");
async function openExplorer(id) {
  if (exploring) return;
  const request = ++explorerRequest;
  exploring = true;
  resumeAfterDialog = stage.playing;
  stage.pause();
  document.documentElement.classList.add("graph-open");
  graphDialog.showModal();
  $("#explorer-fallback").hidden = true;
  $("#explorer-labels").hidden = false;
  try {
    const { createExplorer } = await loadExplorer();
    if (!graphDialog.open || request !== explorerRequest) return;
    explorer = createExplorer({
      selectedId: id,
      onWatch(at) {
        watchAt = at;
        graphDialog.close();
      },
    });
  } catch {
    const fallback = $("#explorer-fallback");
    fallback.hidden = false;
    fallback.textContent = "The explorer couldn’t start. Reload the page to try again.";
    const retry = document.createElement("button");
    retry.className = "pill pill-accent";
    retry.textContent = "Reload this page";
    retry.addEventListener("click", () => location.reload());
    fallback.append(retry);
  }
}
document.querySelectorAll("[data-explore]").forEach((button) =>
  button.addEventListener("click", () => {
    analytics.track("demo_interact");
    openExplorer();
  }),
);
$("#graph-close").addEventListener("click", () => graphDialog.close());
graphDialog.addEventListener("close", () => {
  explorerRequest++;
  explorer?.dispose();
  explorer = null;
  exploring = false;
  document.documentElement.classList.remove("graph-open");
  if (watchAt !== null) {
    // A cited moment: show the call at that point, paused, so it can be checked.
    stage.seek(watchAt);
    stage.pause();
    watchAt = null;
    $("#stage").scrollIntoView({ block: "center", behavior: "instant" });
    playButton.focus({ preventScroll: true });
  } else if (resumeAfterDialog) stage.play();
  syncPlayButton();
});

// About dialog.
$("#about-open").addEventListener("click", () => {
  resumeAfterDialog = stage.playing;
  stage.pause();
  syncPlayButton();
  $("#about-dialog").showModal();
});
$("#about-dialog").addEventListener("close", () => {
  if (resumeAfterDialog) stage.play();
  syncPlayButton();
});
document.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => b.closest("dialog").close()));
$("#about-dialog").addEventListener("click", (e) => {
  if (e.target !== e.currentTarget) return;
  const r = e.currentTarget.getBoundingClientRect();
  if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) e.currentTarget.close();
});

// Signup: the hero form and the closing form post the same launch-list request.
document.querySelectorAll("[data-signup]").forEach((link) =>
  link.addEventListener("click", (event) => {
    event.preventDefault();
    $("#join").scrollIntoView({ behavior: reduced.matches ? "instant" : "smooth", block: "center" });
    $("#email").focus({ preventScroll: true });
  }),
);
document.querySelectorAll(".signup-form").forEach((form) => {
  const button = form.querySelector("[type=submit]"),
    status = form.querySelector(".form-status"),
    label = button.textContent,
    note = status.textContent;
  form.email.addEventListener("focus", () => analytics.track("cta_open"));
  form.querySelectorAll("[name=interests]").forEach((box) => box.addEventListener("change", () => analytics.track("cta_open")));
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!form.reportValidity()) return;
    button.disabled = true;
    button.textContent = "Saving…";
    status.textContent = note;
    status.className = "form-status";
    try {
      const response = await fetch("/api/waitlist", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          email: form.email.value.trim(),
          website: form.website.value,
          consent: "launch-notification-v1",
          interests: [...form.querySelectorAll("[name=interests]:checked")].map((i) => i.value),
          ...analytics.context(),
        }),
        signal: AbortSignal.timeout(15000),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || result.ok !== true) throw Error(result.error || "We couldn’t save your email. Please try again.");
      status.textContent = "You’re in. We’ll email you when your team’s brain is ready.";
      status.classList.add("success");
      button.textContent = "You’re on the list ✓";
      form.email.disabled = true;
      form.querySelectorAll("[name=interests]").forEach((i) => (i.disabled = true));
    } catch (error) {
      status.textContent = error.name === "TimeoutError" || error instanceof TypeError ? "Couldn’t connect. Please try again in a moment." : error.message;
      status.classList.add("error");
      button.disabled = false;
      button.textContent = label;
    }
  });
});

// Keep fixed UI clear of the on-screen keyboard.
function keyboardLayout() {
  if (!window.visualViewport) return;
  const inset = Math.max(0, innerHeight - visualViewport.height - visualViewport.offsetTop);
  document.body.classList.toggle("keyboard-open", inset > 120);
}
visualViewport?.addEventListener("resize", keyboardLayout);
keyboardLayout();
