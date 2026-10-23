import "./admin.css";
const $ = (s) => document.querySelector(s);
const labels = {
  "live-calls": "Live meeting help",
  "company-memory": "Company memory",
  "team-pilot": "A team pilot",
};
const escape = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        char
      ],
  );
const number = (n) => Number(n || 0).toLocaleString();
const date = (value) =>
  new Date(value + "T12:00:00Z").toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
let csrf = "",
  report = null,
  query = "days=30",
  loading = 0;
const localPreview = ["127.0.0.1", "localhost"].includes(location.hostname);
if (localPreview)
  document.querySelector(".data-live").lastChild.textContent =
    " Local preview · includes QA traffic";
async function api(path, options = {}) {
  const response = await fetch(path, options);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401 && path !== "/api/admin/login") {
      location.reload();
    }
    throw Error(body.error || "We couldn’t load that. Please try again.");
  }
  return body;
}
async function session() {
  try {
    const result = await api("/api/admin/session");
    csrf = result.csrf;
    if (result.authenticated) openDashboard();
    else if (result.setup) {
      $("#login-copy").textContent =
        "Create your private dashboard password. This first-time setup is only available on this local computer.";
      $("#password-label").textContent = "Choose a password (12+ characters)";
      $("#password").minLength = 12;
      $("#password").autocomplete = "new-password";
      $("#login-submit").firstChild.textContent = "Create private workspace ";
    }
  } catch (error) {
    $("#login-status").textContent = error.message;
  }
}
$("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("#login-submit").disabled = true;
  $("#login-status").textContent = "";
  try {
    const result = await api("/api/admin/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password: $("#password").value, csrf }),
    });
    csrf = result.csrf;
    $("#password").value = "";
    openDashboard();
  } catch (error) {
    $("#login-status").textContent = error.message;
  } finally {
    $("#login-submit").disabled = false;
  }
});
function openDashboard() {
  $("#login-screen").hidden = true;
  $("#dashboard").hidden = false;
  loadReport();
}
$("#logout").addEventListener("click", async () => {
  try {
    await api("/api/admin/logout", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ csrf }),
    });
    location.reload();
  } catch (error) {
    showError(error.message);
  }
});
function showError(message) {
  $("#dashboard-error").textContent = message;
  $("#dashboard-error").hidden = false;
}
async function loadReport() {
  const request = ++loading;
  $("#dashboard-error").hidden = true;
  try {
    const data = await api("/api/admin/report?" + query);
    if (request !== loading) return;
    report = data;
    render(data);
  } catch (error) {
    showError(error.message);
  }
}
const chartMaximum = (daily) =>
  Math.ceil(Math.max(1, ...daily.flatMap((d) => [d.visits, d.signups])) / 3) *
  3;
function linePoints(daily, key, w, h) {
  const max = chartMaximum(daily);
  return daily.map((day, index) => ({
    x: daily.length === 1 ? w / 2 : (index / (daily.length - 1)) * w,
    y: h - (day[key] / max) * h,
  }));
}
function trendSVG(daily, { width = 680, height = 190, dark = true } = {}) {
  const left = 24,
    right = 10,
    top = 10,
    bottom = 27,
    w = width - left - right,
    h = height - top - bottom;
  const max = chartMaximum(daily);
  const color = dark ? "#42647f" : "#8c9da9",
    grid = dark ? "#ffffff0b" : "#e8eef1";
  let content = `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="Daily visits and signups from ${escape(daily[0]?.date)} to ${escape(daily.at(-1)?.date)}"><defs><linearGradient id="traffic-fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#72d4f4" stop-opacity=".19"/><stop offset="100%" stop-color="#72d4f4" stop-opacity="0"/></linearGradient></defs>`;
  for (let i = 0; i <= 3; i++) {
    const y = top + (h * i) / 3;
    content += `<path d="M${left} ${y}H${width - right}" stroke="${grid}"/><text x="0" y="${y + 3}" fill="${color}" font-family="Arial" font-size="8">${Math.round(max * (1 - i / 3))}</text>`;
  }
  const points = linePoints(daily, "visits", w, h);
  const path = points
    .map(
      (p, i) =>
        `${i ? "L" : "M"}${(p.x + left).toFixed(2)} ${(p.y + top).toFixed(2)}`,
    )
    .join(" ");
  content += `<path d="${path} L${left + w} ${top + h}H${left}Z" fill="url(#traffic-fill)"/><path d="${path}" fill="none" stroke="#70cdea" stroke-width="1.7" stroke-linejoin="round"/>`;
  const signup = linePoints(daily, "signups", w, h)
    .map((p, i) => `${i ? "L" : "M"}${p.x + left} ${p.y + top}`)
    .join(" ");
  content += `<path d="${signup}" fill="none" stroke="#a5b4f9" stroke-width="1.6" stroke-linejoin="round"/>`;
  const steps = Math.min(5, daily.length);
  for (let i = 0; i < steps; i++) {
    const index = Math.round((i / (steps - 1 || 1)) * (daily.length - 1));
    const x =
      left + (daily.length === 1 ? w / 2 : (index / (daily.length - 1)) * w);
    content += `<text x="${x}" y="${height - 5}" text-anchor="${i === 0 ? "start" : i === steps - 1 ? "end" : "middle"}" fill="${color}" font-family="Arial" font-size="8">${escape(date(daily[index].date))}</text>`;
  }
  return content + "</svg>";
}
function bars(element, entries, max) {
  $(element).innerHTML = entries
    .map(
      ([label, count]) =>
        `<div class="bar-item"><div><span>${escape(label)}</span><strong>${number(count)}</strong></div><div class="bar-track"><i style="width:${max ? Math.min(100, (count / max) * 100) : 0}%"></i></div></div>`,
    )
    .join("");
}
function render(data) {
  $("#metric-visits").textContent = number(data.visits);
  $("#metric-engaged").textContent = number(data.engaged);
  $("#metric-signups").textContent = number(data.signups);
  $("#metric-conversion").textContent =
    data.conversion_rate === null ? "—" : data.conversion_rate + "%";
  $("#start-date").value = data.start;
  $("#end-date").value = data.end;
  $("#date-label").textContent =
    `UTC · ${date(data.start)} — ${date(data.end)}`;
  $("#traffic-chart").innerHTML = trendSVG(data.daily);
  $("#pageview-total").textContent = `${number(data.pageviews)} pageviews`;
  $("#all-time-total").textContent =
    `${number(data.all_time_signups)} all-time signups`;
  const funnel = [
    ["Visited the experience", data.visits],
    ["Meeting started (autoplay)", data.demo_starts],
    ["Engaged with signup", data.cta_opens],
    ["Became a new signup", data.converted_visits],
  ];
  $("#funnel").innerHTML = funnel
    .map(
      ([name, count]) =>
        `<div class="funnel-row"><div><span>${name}</span><strong>${number(count)}</strong></div><div class="funnel-track"><i style="width:${data.visits ? Math.min(100, (count / data.visits) * 100) : 0}%"></i></div></div>`,
    )
    .join("");
  $("#completion-rate").textContent =
    data.completion_rate === null ? "—" : data.completion_rate + "%";
  bars(
    "#demo-bars",
    [
      ["Started (autoplay)", data.demo_starts],
      ["Halfway through", data.milestones.demo_50],
      ["Watched to the end", data.demo_completions],
      ["Used playback controls", data.demo_interactions],
    ],
    data.demo_starts,
  );
  bars(
    "#interest-bars",
    Object.entries(labels).map(([id, label]) => [label, data.interests[id]]),
    Math.max(1, data.signups),
  );
  bars(
    "#chapter-bars",
    [
      ["Live calls", data.chapters.meeting],
      ["Connected work", data.chapters.connected],
      ["Company brain", data.chapters.company],
    ],
    Math.max(1, data.visits),
  );
  $("#device-split").innerHTML = Object.entries(data.devices)
    .map(
      ([device, count]) =>
        `<span><b>${data.visits ? Math.round((count / data.visits) * 100) : 0}%</b> ${device}</span>`,
    )
    .join("");
  $("#campaign-rows").innerHTML = data.campaigns
    .map(
      (row) =>
        `<tr><td>${escape(row.campaign)}</td><td>${escape(row.source)} <span style="color:#456b85">/ ${escape(row.medium)}</span></td><td>${number(row.visits)}</td><td>${number(row.signups)}</td><td>${number(row.conversions)}</td><td><em>${row.visits ? ((row.conversions / row.visits) * 100).toFixed(1) + "%" : "—"}</em></td></tr>`,
    )
    .join("");
  $("#campaign-empty").hidden = data.campaigns.length > 0;
  $("#export-csv").href = "/api/admin/export.csv?" + query;
  renderLeads();
  $("#updated-at").textContent =
    "Updated " +
    new Date(data.generated_at).toLocaleTimeString(undefined, {
      hour: "2-digit",
      minute: "2-digit",
    });
  $("#print-view").innerHTML = reportSVG(data);
}
function renderLeads() {
  if (!report) return;
  const search = $("#lead-search").value.toLowerCase();
  const leads = report.leads.filter((lead) =>
    [
      lead.email,
      ...lead.interests.map((id) => labels[id] || id),
      lead.campaign.utm_campaign || "",
    ]
      .join(" ")
      .toLowerCase()
      .includes(search),
  );
  $("#lead-rows").innerHTML = leads
    .map(
      (lead) =>
        `<tr><td>${escape(lead.email)}</td><td>${lead.interests.map((id) => `<span class="interest-tag">${escape(labels[id] || id)}</span>`).join("") || "—"}</td><td>${escape(lead.campaign.utm_campaign || lead.campaign.utm_source || "Direct / untagged")}</td><td>${escape(new Date(lead.joined_at).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }))}</td></tr>`,
    )
    .join("");
  $("#lead-empty").hidden = leads.length > 0;
  $("#lead-empty").textContent = search
    ? "No people match this search."
    : "No signups in this period yet. Your next connection is out there.";
}
$("#lead-search").addEventListener("input", renderLeads);
document.querySelectorAll("[data-days]").forEach((button) =>
  button.addEventListener("click", () => {
    query = "days=" + button.dataset.days;
    document
      .querySelectorAll("[data-days]")
      .forEach((b) => b.classList.toggle("active", b === button));
    loadReport();
  }),
);
$("#date-form").addEventListener("submit", (event) => {
  event.preventDefault();
  query = new URLSearchParams({
    start: $("#start-date").value,
    end: $("#end-date").value,
  }).toString();
  document
    .querySelectorAll("[data-days]")
    .forEach((b) => b.classList.remove("active"));
  loadReport();
});
document.querySelectorAll(".side-link").forEach((link) =>
  link.addEventListener("click", () => {
    document
      .querySelectorAll(".side-link")
      .forEach((a) => a.classList.toggle("selected", a === link));
  }),
);
$("#campaign-url").value =
  location.origin.includes("127.0.0.1") || location.hostname === "localhost"
    ? "https://calla.nomonlab.com"
    : location.origin;
$("#campaign-form").addEventListener("submit", (event) => {
  event.preventDefault();
  try {
    const url = new URL($("#campaign-url").value);
    if (!["http:", "https:"].includes(url.protocol))
      throw Error("Use an HTTP or HTTPS landing-page URL.");
    url.searchParams.set("utm_source", $("#campaign-source").value.trim());
    url.searchParams.set("utm_medium", $("#campaign-medium").value.trim());
    url.searchParams.set("utm_campaign", $("#campaign-name").value.trim());
    $("#campaign-link").value = url.toString();
    $("#campaign-result").hidden = false;
  } catch (error) {
    showError(error.message);
  }
});
$("#copy-campaign").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText($("#campaign-link").value);
    $("#copy-campaign").textContent = "Copied ✓";
  } catch {
    $("#campaign-link").select();
    $("#copy-campaign").textContent = "Select & copy";
  }
});
function reportSVG(data) {
  let s = `<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1080" viewBox="0 0 1600 1080"><rect width="1600" height="1080" fill="#f5f8fa"/><rect width="1600" height="220" fill="#092233"/><circle cx="1480" cy="30" r="220" fill="none" stroke="#70d8fc" stroke-opacity=".1" stroke-width="50"/><text x="72" y="66" font-family="Arial" font-size="25" font-weight="bold" fill="#a5eaff">calla.</text><text x="72" y="118" font-family="Arial" font-size="10" letter-spacing="3" fill="#77acc4">INTEREST &amp; ENGAGEMENT</text><text x="72" y="174" font-family="Georgia" font-size="43" fill="#f1f8fc">Every connection starts somewhere.</text><text x="1528" y="172" text-anchor="end" font-family="Arial" font-size="15" fill="#b6cedc">${escape(date(data.start))} – ${escape(date(data.end))}, ${escape(data.end.slice(0, 4))}</text>`;
  const metrics = [
    ["VISITS", number(data.visits), "Anonymous browsing sessions"],
    ["ENGAGED VISITS", number(data.engaged), "At least 10 active seconds"],
    ["NEW SIGNUPS", number(data.signups), "Deduplicated registrations"],
    [
      "SIGNUP CONVERSION",
      data.conversion_rate === null ? "—" : data.conversion_rate + "%",
      "Visits that became a new signup",
    ],
  ];
  metrics.forEach(([label, value, note], i) => {
    const x = 72 + i * 370;
    s += `<rect x="${x}" y="252" width="346" height="151" rx="10" fill="${i === 3 ? "#dff4fa" : "white"}" stroke="#dce6ec"/><text x="${x + 24}" y="283" font-family="Arial" font-size="10" letter-spacing="1.5" fill="#628294">${label}</text><text x="${x + 24}" y="346" font-family="Arial" font-size="47" fill="#14364a">${value}</text><text x="${x + 24}" y="379" font-family="Arial" font-size="10" fill="#7c929f">${note}</text>`;
  });
  s += `<rect x="72" y="431" width="935" height="295" rx="10" fill="white" stroke="#dce6ec"/><text x="98" y="468" font-family="Georgia" font-size="23" fill="#18394d">People finding their way here.</text><text x="840" y="468" font-family="Arial" font-size="10" fill="#659ab0">Visits / Signups</text><g transform="translate(98,488)">${trendSVG(data.daily, { width: 875, height: 210, dark: false })}</g>`;
  s += `<rect x="1033" y="431" width="495" height="295" rx="10" fill="white" stroke="#dce6ec"/><text x="1060" y="468" font-family="Georgia" font-size="23" fill="#18394d">From curiosity to connection.</text>`;
  [
    ["Meeting started (autoplay)", data.demo_starts],
    ["Watched to the end", data.demo_completions],
    ["Engaged with signup", data.cta_opens],
    ["Converted visits", data.converted_visits],
  ].forEach(([label, n], i) => {
    const y = 510 + i * 50;
    s += `<text x="1060" y="${y}" font-family="Arial" font-size="13" fill="#6d8a9c">${label}</text><text x="1498" y="${y}" text-anchor="end" font-family="Arial" font-size="19" fill="#17415a">${number(n)}</text><rect x="1060" y="${y + 10}" width="438" height="4" rx="2" fill="#eaf1f5"/><rect x="1060" y="${y + 10}" width="${data.visits ? Math.min(438, (n / data.visits) * 438) : 0}" height="4" rx="2" fill="#64b9d7"/>`;
  });
  s += `<rect x="72" y="754" width="705" height="224" rx="10" fill="white" stroke="#dce6ec"/><text x="98" y="792" font-family="Georgia" font-size="23" fill="#18394d">What resonates.</text>`;
  Object.entries(labels).forEach(([id, label], i) => {
    const y = 834 + i * 48;
    s += `<text x="98" y="${y}" font-family="Arial" font-size="13" fill="#6d8a9c">${label}</text><text x="750" y="${y}" text-anchor="end" font-family="Arial" font-size="18" fill="#17415a">${number(data.interests[id])}</text><rect x="98" y="${y + 10}" width="652" height="4" rx="2" fill="#eaf1f5"/><rect x="98" y="${y + 10}" width="${data.signups ? (data.interests[id] / data.signups) * 652 : 0}" height="4" rx="2" fill="#89adc4"/>`;
  });
  s += `<rect x="803" y="754" width="725" height="224" rx="10" fill="white" stroke="#dce6ec"/><text x="830" y="792" font-family="Georgia" font-size="23" fill="#18394d">Campaigns bringing people in.</text>`;
  if (!data.campaigns.length)
    s += `<text x="830" y="840" font-family="Arial" font-size="13" fill="#8b9eaa">No attributed visits in this period yet.</text>`;
  data.campaigns.slice(0, 3).forEach((row, i) => {
    const y = 837 + i * 48;
    const label = (
      row.campaign === "Unspecified" ? row.source : row.campaign
    ).slice(0, 43);
    s += `<text x="830" y="${y}" font-family="Arial" font-size="13" fill="#34596e">${escape(label)}</text><text x="830" y="${y + 18}" font-family="Arial" font-size="10" fill="#8a9fac">${escape(row.source)} / ${escape(row.medium)}</text><text x="1500" y="${y + 5}" text-anchor="end" font-family="Arial" font-size="16" fill="#17415a">${number(row.visits)} visits · ${number(row.signups)} signups</text>`;
  });
  s += `<text x="72" y="1022" font-family="Arial" font-size="10" fill="#849aa8">${localPreview ? "Local preview · includes QA traffic. " : ""}Recorded first-party engagement. Visits are sessions, not unique people.</text><text x="1528" y="1022" text-anchor="end" font-family="Arial" font-size="10" fill="#849aa8">${escape(new Date(data.generated_at).toISOString().slice(0, 10))} · PRIVATE REPORT</text></svg>`;
  return s;
}
$("#export-png").addEventListener("click", async () => {
  if (!report) return;
  const button = $("#export-png");
  button.disabled = true;
  let source;
  try {
    const svg = reportSVG(report);
    source = URL.createObjectURL(new Blob([svg], { type: "image/svg+xml" }));
    const image = new Image();
    image.src = source;
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = 2400;
    canvas.height = 1620;
    const ctx = canvas.getContext("2d");
    ctx.drawImage(image, 0, 0, 2400, 1620);
    const blob = await new Promise((resolve) =>
      canvas.toBlob(resolve, "image/png"),
    );
    if (!blob) throw Error();
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `calla-engagement-${report.start}-${report.end}.png`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch {
    showError(
      "The image export couldn’t finish. You can save the PDF report instead.",
    );
  } finally {
    if (source) URL.revokeObjectURL(source);
    button.disabled = false;
  }
});
$("#print-report").addEventListener("click", () => {
  if (report) window.print();
});
setInterval(() => {
  if (report && !document.hidden) loadReport();
}, 60000);
session();

// Fetch authenticated CSV explicitly so a failed session produces a readable
// error instead of a silent attachment navigation or an HTML download.
$("#export-csv").addEventListener("click", async (event) => {
  event.preventDefault();
  const link = event.currentTarget;
  if (link.getAttribute("aria-disabled") === "true") return;
  link.setAttribute("aria-disabled", "true");
  link.textContent = "Exporting…";
  try {
    const response = await fetch(link.href, {
      credentials: "same-origin",
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      throw Error(
        body.error || "The CSV export couldn’t finish. Please try again.",
      );
    }
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const download = document.createElement("a");
    download.href = url;
    download.download = `calla-interests-${report.start}-${report.end}.csv`;
    document.body.append(download);
    download.click();
    download.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (error) {
    showError(
      error.message || "The CSV export couldn’t finish. Please try again.",
    );
  } finally {
    link.removeAttribute("aria-disabled");
    link.textContent = "Export CSV ↓";
  }
});
