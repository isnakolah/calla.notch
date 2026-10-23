// Timings are generated from the native demo. These annotations explain the
// knowledge-graph vision; they are not output from a production graph engine.
export const nodes = [
  {
    id: "meeting",
    label: "Weekly check-in",
    type: "Conversation",
    position: [0, 0.7, 0.6],
  },
  {
    id: "report",
    label: "Weekly report",
    type: "Project",
    position: [-0.6, 0.35, 0.75],
  },
  {
    id: "friday",
    label: "Friday",
    type: "Deadline",
    position: [0.65, 0.55, 0.5],
  },
  { id: "you", label: "You", type: "Person", position: [-1, -0.15, 0.35] },
  {
    id: "draft",
    label: "Draft · Wednesday",
    type: "Responsibility",
    position: [-0.45, -0.6, 0.65],
  },
  { id: "maya", label: "Maya", type: "Person", position: [0.85, -0.1, 0.45] },
  {
    id: "review",
    label: "Review · Thursday",
    type: "Next step",
    position: [0.45, -0.65, 0.6],
  },
  {
    id: "template",
    label: "Last week’s template",
    type: "Existing knowledge",
    position: [-0.8, 0.55, -0.35],
  },
  {
    id: "finance",
    label: "Finance’s figures",
    type: "Dependency",
    position: [0.45, 0.05, -0.6],
  },
];

// A relationship's repeated confirmation increases its illustrative strength.
// Its state is calculated from elapsed time, never accumulated on each replay.
export const events = [
  {
    at: 0,
    focus: ["meeting", "template"],
    edges: [],
    kicker: "A LITTLE CONTEXT",
    text: "A familiar meeting. Some knowledge already exists.",
  },
  {
    at: 4,
    focus: ["meeting", "report", "friday"],
    edges: [
      ["meeting", "report"],
      ["report", "friday"],
    ],
    kicker: "THE DEADLINE CONNECTS",
    text: "The report and its Friday deadline now belong to the same story.",
  },
  {
    at: 8,
    focus: ["you", "draft", "report"],
    edges: [
      ["you", "draft"],
      ["draft", "report"],
    ],
    kicker: "A RESPONSIBILITY TAKES SHAPE",
    text: "Who is doing what — and when — becomes connected context.",
  },
  {
    at: 12,
    focus: ["maya", "review", "friday"],
    edges: [
      ["maya", "review"],
      ["review", "report"],
      ["report", "friday"],
    ],
    kicker: "THE NEXT STEP JOINS IN",
    text: "Maya’s review connects the draft to the Friday deadline.",
  },
  {
    at: 18,
    focus: ["template", "report", "meeting"],
    edges: [
      ["template", "report"],
      ["meeting", "report"],
    ],
    kicker: "PAST KNOWLEDGE BECOMES USEFUL",
    text: "Last week’s template connects to this week’s work.",
  },
  {
    at: 24,
    focus: ["finance", "report"],
    open: ["finance"],
    edges: [["finance", "report"]],
    kicker: "SOMETHING IS STILL OPEN",
    text: "Missing figures are a dependency, not a settled fact.",
  },
  {
    at: 29,
    focus: ["you", "finance", "draft"],
    open: ["finance"],
    edges: [
      ["you", "finance"],
      ["finance", "draft"],
    ],
    kicker: "A FOLLOW-UP HAS AN OWNER",
    text: "You take the follow-up. The missing figures remain visibly open.",
  },
  {
    at: 35,
    focus: ["finance", "report", "draft"],
    resolved: ["finance"],
    edges: [
      ["finance", "report"],
      ["finance", "draft"],
    ],
    kicker: "THE PICTURE UPDATES",
    text: "Finance confirms this afternoon. The open dependency gets an update.",
  },
  {
    at: 39,
    focus: ["draft", "review", "friday"],
    edges: [
      ["you", "draft"],
      ["maya", "review"],
      ["draft", "report"],
      ["review", "report"],
      ["report", "friday"],
    ],
    kicker: "THE CONNECTIONS GROW STRONGER",
    text: "The team confirms the same plan. Existing connections become stronger.",
  },
  {
    at: 42,
    focus: ["meeting", "report", "you", "maya"],
    edges: [],
    kicker: "ONE CONVERSATION. CONNECTED CONTEXT.",
    text: "People, decisions and next steps — a picture the next conversation can build on.",
  },
];

export function meetingState(time) {
  const elapsed = Math.max(0, Math.min(45, Number(time) || 0));
  const visited = new Set();
  const links = new Map();
  const open = new Set();
  let current = events[0];
  for (const event of events) {
    if (event.at > elapsed) break;
    current = event;
    event.focus.forEach((id) => visited.add(id));
    event.open?.forEach((id) => open.add(id));
    event.resolved?.forEach((id) => open.delete(id));
    for (const [a, b] of event.edges) {
      const key = [a, b].sort().join(":");
      const old = links.get(key);
      links.set(key, {
        a,
        b,
        strength: (old?.strength ?? 0) + 1,
        born: old?.born ?? event.at,
        updated: event.at,
      });
    }
  }
  return { elapsed, current, visited, links: [...links.values()], open };
}

export function currentTurn(timeline, time) {
  return timeline.turns.findLast((turn) => turn.at <= time) ?? null;
}
