import { nodes as meetingNodes, events, meetingState } from "./meeting.js";
import nativeTimeline from "../public/demo/timeline.json" with { type: "json" };

// One deliberately fictional company, shared by the film and both 3D views.
// Native evidence refers to the scripted recording, never to a real user's call.
export { nativeTimeline };
export const clusters = {
  reporting: {
    label: "The weekly report",
    color: "#83e9ff",
    center: [-3.2, 0.5, 0.5],
  },
  launch: {
    label: "The customer launch",
    color: "#b5a1ff",
    center: [2.8, 1.1, -0.6],
  },
  planning: {
    label: "The next quarter",
    color: "#efc48f",
    center: [0.4, -2.7, 0.2],
  },
};

export const sources = [
  ...nativeTimeline.turns.map((turn, i) => ({
    id: `native-${turn.at}`,
    title: "Weekly check-in",
    kind: "Scripted meeting",
    at: turn.at,
    speaker: turn.source === "me" ? "You" : "Maya",
    excerpt: turn.text,
    summaryAt: nativeTimeline.summaries[i].at,
  })),
  {
    id: "launch-call",
    title: "Customer launch · planning call",
    kind: "Fictional meeting",
    excerpt:
      "Alex: Let’s launch the customer portal on the 28th. Nia owns the onboarding guide; Leo will finish the accessibility review. Maya will coordinate the pilot with the delivery team.",
  },
  {
    id: "launch-brief",
    title: "Customer portal · project brief",
    kind: "Fictional document",
    excerpt:
      "Pilot: twenty customer teams. Include document uploads, shipment tracking and email alerts. Success means fewer support requests and a clear onboarding path. The launch needs an approved budget and a completed accessibility review.",
  },
  {
    id: "budget-call",
    title: "Quarterly planning · budget review",
    kind: "Fictional meeting",
    excerpt:
      "Sam: Reserve the pilot budget for the customer portal. Finance will confirm capacity after the quarterly forecast. You will consolidate the forecast; Maya will bring the delivery estimate to our next planning meeting.",
  },
  {
    id: "forecast-doc",
    title: "Next quarter · operating plan",
    kind: "Fictional document",
    excerpt:
      "Priorities: a successful customer pilot, a reusable weekly reporting process, and a sustainable delivery capacity. Budget approval follows the forecast review. Track customer activation and delivery capacity in the same scorecard.",
  },
  {
    id: "template-doc",
    title: "Last week’s report template",
    kind: "Fictional document",
    excerpt:
      "A reusable report structure: progress, decisions, owners, deadlines, and open dependencies. Referenced during the scripted weekly check-in.",
  },
];

const nativeEvidence = {
  meeting: [4],
  report: [4, 39],
  friday: [4, 12, 39],
  you: [8, 29],
  draft: [8, 39],
  maya: [12],
  review: [12, 39],
  template: [18],
  finance: [24, 29, 35],
};
const extra = [
  [
    "delivery",
    "Delivery team",
    "Team",
    "reporting",
    "Maya and you connect the report to the customer pilot.",
    "launch-call",
  ],
  [
    "scorecard",
    "Team scorecard",
    "Document",
    "reporting",
    "A shared view of delivery capacity and customer activation.",
    "forecast-doc",
  ],
  [
    "report-decision",
    "Reuse the template",
    "Decision",
    "reporting",
    "Keep the same report structure so the team can compare progress.",
    "native-18",
  ],
  [
    "wednesday",
    "Wednesday",
    "Deadline",
    "reporting",
    "The first draft is ready before the review.",
    "native-8",
  ],
  [
    "thursday",
    "Thursday",
    "Deadline",
    "reporting",
    "Maya reviews the draft before Friday.",
    "native-12",
  ],
  [
    "followup",
    "Finance follow-up",
    "Task",
    "reporting",
    "You follow up on the missing figures.",
    "native-29",
  ],
  [
    "portal",
    "Customer portal",
    "Project",
    "launch",
    "A twenty-team pilot connecting uploads, tracking and alerts.",
    "launch-brief",
  ],
  [
    "alex",
    "Alex",
    "Person",
    "launch",
    "Coordinates the customer portal launch.",
    "launch-call",
  ],
  [
    "nia",
    "Nia",
    "Person",
    "launch",
    "Owns the onboarding guide for the pilot.",
    "launch-call",
  ],
  [
    "leo",
    "Leo",
    "Person",
    "launch",
    "Owns the accessibility review.",
    "launch-call",
  ],
  [
    "engineering",
    "Engineering",
    "Team",
    "launch",
    "Builds the portal and completes the accessibility review.",
    "launch-call",
  ],
  [
    "design",
    "Design",
    "Team",
    "launch",
    "Makes the first customer experience clear and accessible.",
    "launch-brief",
  ],
  [
    "pilot",
    "Twenty-team pilot",
    "Decision",
    "launch",
    "Start with twenty customer teams before a wider launch.",
    "launch-brief",
  ],
  [
    "onboarding",
    "Onboarding guide",
    "Document",
    "launch",
    "Nia’s guide explains the first steps for pilot customers.",
    "launch-call",
  ],
  [
    "accessibility",
    "Accessibility review",
    "Task",
    "launch",
    "Leo checks the portal before the launch.",
    "launch-call",
  ],
  [
    "launch-day",
    "Launch · 28th",
    "Deadline",
    "launch",
    "The proposed customer portal launch date.",
    "launch-call",
  ],
  [
    "launch-meeting",
    "Launch planning",
    "Meeting",
    "launch",
    "The conversation connecting the pilot, owners and launch date.",
    "launch-call",
  ],
  [
    "brief",
    "Project brief",
    "Document",
    "launch",
    "The original scope and success criteria for the customer portal.",
    "launch-brief",
  ],
  [
    "activation",
    "Customer activation",
    "Metric",
    "launch",
    "Understand whether pilot teams can get started successfully.",
    "forecast-doc",
  ],
  [
    "quarter",
    "Next quarter",
    "Project",
    "planning",
    "Make room for the pilot and sustainable delivery.",
    "forecast-doc",
  ],
  [
    "sam",
    "Sam",
    "Person",
    "planning",
    "Coordinates the budget and capacity review.",
    "budget-call",
  ],
  [
    "finance-team",
    "Finance",
    "Team",
    "planning",
    "Confirms figures, forecast and available pilot budget.",
    "budget-call",
  ],
  [
    "budget",
    "Pilot budget",
    "Decision",
    "planning",
    "Reserve funding for the pilot after the forecast review.",
    "budget-call",
  ],
  [
    "forecast",
    "Quarterly forecast",
    "Document",
    "planning",
    "You consolidate the forecast before budget approval.",
    "budget-call",
  ],
  [
    "capacity",
    "Delivery capacity",
    "Metric",
    "planning",
    "Maya brings the delivery estimate into planning.",
    "budget-call",
  ],
  [
    "budget-meeting",
    "Budget review",
    "Meeting",
    "planning",
    "The discussion connecting the forecast and pilot funding.",
    "budget-call",
  ],
  [
    "operating-plan",
    "Operating plan",
    "Document",
    "planning",
    "The company’s priorities, resources and shared scorecard.",
    "forecast-doc",
  ],
  [
    "next-meeting",
    "Next planning meeting",
    "Meeting",
    "planning",
    "A future conversation starts with this context.",
    "budget-call",
  ],
  [
    "approval",
    "Budget approval",
    "Task",
    "planning",
    "Approve the pilot budget after the forecast review.",
    "forecast-doc",
  ],
  [
    "estimate",
    "Delivery estimate",
    "Task",
    "planning",
    "Maya prepares the estimate for the next planning meeting.",
    "budget-call",
  ],
  [
    "support",
    "Fewer support requests",
    "Metric",
    "launch",
    "One of the outcomes the pilot will be measured against.",
    "launch-brief",
  ],
];

export const graphNodes = [
  ...meetingNodes.map((n) => ({
    ...n,
    type:
      {
        Conversation: "Meeting",
        Responsibility: "Task",
        "Next step": "Task",
        "Existing knowledge": "Document",
      }[n.type] || n.type,
    cluster: "reporting",
    description:
      events.find((e) => e.focus.includes(n.id) && e.at > 0)?.text ||
      "The conversation behind the connections.",
    sources: nativeEvidence[n.id].map((t) => `native-${t}`),
  })),
  ...extra.map(([id, label, type, cluster, description, source]) => ({
    id,
    label,
    type,
    cluster,
    description,
    sources: [source],
  })),
];

export const edgeKey = (a, b) => [a, b].sort().join(":");
const nativeRelations = [
  ["meeting", "report", "discusses", 4],
  ["report", "friday", "due", 4],
  ["you", "draft", "owns", 8],
  ["draft", "report", "contributes to", 8],
  ["maya", "review", "owns", 12],
  ["review", "report", "checks", 12],
  ["template", "report", "used by", 18],
  ["finance", "report", "needed for", 24],
  ["you", "finance", "follows up", 29],
  ["finance", "draft", "informs", 29],
];
const relations = [
  ["delivery", "you", "includes", "launch-call"],
  ["delivery", "maya", "includes", "launch-call"],
  ["delivery", "portal", "coordinates", "launch-call"],
  ["delivery", "scorecard", "tracks", "forecast-doc"],
  ["report-decision", "template", "selects", "native-18"],
  ["report-decision", "report", "shapes", "native-18"],
  ["draft", "wednesday", "due", "native-8"],
  ["review", "thursday", "due", "native-12"],
  ["you", "followup", "owns", "native-29"],
  ["followup", "finance", "resolves", "native-29"],
  ["template", "scorecard", "informs", "forecast-doc"],
  ["alex", "portal", "coordinates", "launch-call"],
  ["nia", "onboarding", "authors", "launch-call"],
  ["leo", "accessibility", "owns", "launch-call"],
  ["engineering", "leo", "includes", "launch-call"],
  ["engineering", "portal", "builds", "launch-call"],
  ["design", "onboarding", "shapes", "launch-brief"],
  ["design", "accessibility", "supports", "launch-brief"],
  ["portal", "pilot", "starts with", "launch-brief"],
  ["portal", "onboarding", "needs", "launch-brief"],
  ["portal", "accessibility", "needs", "launch-brief"],
  ["portal", "launch-day", "targets", "launch-call"],
  ["launch-meeting", "portal", "discusses", "launch-call"],
  ["launch-meeting", "alex", "includes", "launch-call"],
  ["launch-meeting", "maya", "includes", "launch-call"],
  ["brief", "portal", "defines", "launch-brief"],
  ["pilot", "activation", "measured by", "forecast-doc"],
  ["pilot", "support", "measured by", "launch-brief"],
  ["portal", "budget", "needs", "launch-brief"],
  ["sam", "budget", "coordinates", "budget-call"],
  ["finance-team", "sam", "includes", "budget-call"],
  ["finance-team", "finance", "supplies", "native-35"],
  ["finance-team", "forecast", "reviews", "budget-call"],
  ["quarter", "portal", "prioritizes", "forecast-doc"],
  ["quarter", "capacity", "balances", "forecast-doc"],
  ["quarter", "operating-plan", "defined by", "forecast-doc"],
  ["you", "forecast", "consolidates", "budget-call"],
  ["maya", "estimate", "owns", "budget-call"],
  ["estimate", "capacity", "explains", "budget-call"],
  ["budget-meeting", "forecast", "reviews", "budget-call"],
  ["budget-meeting", "budget", "discusses", "budget-call"],
  ["budget", "approval", "requires", "forecast-doc"],
  ["approval", "forecast", "follows", "forecast-doc"],
  ["next-meeting", "estimate", "uses", "budget-call"],
  ["next-meeting", "budget-meeting", "continues", "budget-call"],
  ["operating-plan", "scorecard", "uses", "forecast-doc"],
  ["scorecard", "activation", "tracks", "forecast-doc"],
  ["scorecard", "capacity", "tracks", "forecast-doc"],
  ["report", "operating-plan", "informs", "forecast-doc"],
];
export const graphEdges = [
  ...nativeRelations.map(([a, b, label, at]) => ({
    id: edgeKey(a, b),
    a,
    b,
    label,
    sources: [`native-${at}`],
    live: true,
  })),
  ...relations.map(([a, b, label, source]) => ({
    id: edgeKey(a, b),
    a,
    b,
    label,
    sources: [source],
    live: false,
  })),
];
export const nodeById = new Map(graphNodes.map((n) => [n.id, n]));
export const sourceById = new Map(sources.map((s) => [s.id, s]));

// Fixed cluster layouts avoid physics jitter, including during search and resize.
for (const [cluster, config] of Object.entries(clusters)) {
  const members = graphNodes.filter((n) => n.cluster === cluster);
  members.forEach((node, i) => {
    const angle = i * 2.399963229728653,
      radius = 0.65 + Math.sqrt(i / members.length) * 1.65;
    node.graphPosition = [
      config.center[0] + Math.cos(angle) * radius,
      config.center[1] + Math.sin(angle) * radius * 0.78,
      config.center[2] + Math.sin(i * 1.7) * 1.25,
    ];
    node.position ??= [
      Math.cos(angle) * 0.95,
      Math.sin(angle) * 1.1,
      Math.sin(i * 1.7) * 0.85,
    ];
  });
}

export const captures = nativeTimeline.turns.map((turn, i) => ({
  ...events.find((e) => e.at === turn.at),
  source: turn.source,
  summaryAt: nativeTimeline.summaries[i].at,
  arrivalAt: nativeTimeline.summaries[i].at + 0.65,
  target: events
    .find((e) => e.at === turn.at)
    .focus.find((id) => !["meeting", "you", "maya"].includes(id)),
}));
const arrivalFor = (at) => captures.find((c) => c.at === at)?.arrivalAt ?? at;
const clamp = (n) => Math.max(0, Math.min(1, n));

export function storyState(time) {
  const elapsed = Math.max(
    0,
    Math.min(nativeTimeline.duration, Number(time) || 0),
  );
  const capture = captures.findLast((c) => c.at <= elapsed) ?? null;
  const arrived = captures.findLast((c) => c.arrivalAt <= elapsed);
  const state = meetingState(arrived?.at ?? 0);
  const births = new Map([
    ["meeting", 0],
    ["template", 0],
  ]);
  for (const c of captures) {
    if (c.arrivalAt > elapsed) break;
    for (const id of c.focus) if (!births.has(id)) births.set(id, c.arrivalAt);
  }
  state.links = state.links.map((link) => ({
    ...link,
    born: arrivalFor(link.born),
    updated: arrivalFor(link.updated),
  }));
  let phase = "listening",
    phaseProgress = 0;
  if (capture) {
    if (elapsed < capture.at + 0.15) phase = "listening";
    else if (elapsed < capture.at + 0.8) {
      phase = "capture";
      phaseProgress = clamp((elapsed - capture.at - 0.15) / 0.65);
    } else if (elapsed < capture.summaryAt) {
      phase = "understanding";
      phaseProgress = clamp(
        (elapsed - capture.at - 0.8) / (capture.summaryAt - capture.at - 0.8),
      );
    } else if (elapsed < capture.arrivalAt) {
      phase = "transfer";
      phaseProgress = clamp((elapsed - capture.summaryAt) / 0.65);
    } else if (elapsed < capture.arrivalAt + 0.45) {
      phase = "forming";
      phaseProgress = clamp((elapsed - capture.arrivalAt) / 0.45);
    } else if (elapsed < capture.arrivalAt + 1.1) {
      phase = "linking";
      phaseProgress = clamp((elapsed - capture.arrivalAt - 0.45) / 0.65);
    } else {
      phase = "connected";
      phaseProgress = 1;
    }
  }
  return { ...state, elapsed, births, capture, phase, phaseProgress };
}

export function relatedNodes(id) {
  return new Set([
    id,
    ...graphEdges
      .filter((e) => e.a === id || e.b === id)
      .flatMap((e) => [e.a, e.b]),
  ]);
}
