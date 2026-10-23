import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { currentTurn, events, meetingState, nodes } from "../src/meeting.js";

test("backwards seeking restores graph, strengths and unresolved state", () => {
  assert.equal(meetingState(26).open.has("finance"), true);
  assert.equal(meetingState(37).open.has("finance"), false);
  const confirmed = meetingState(41).links.find(
    (edge) => [edge.a, edge.b].sort().join(":") === "friday:report",
  );
  const early = meetingState(5).links.find(
    (edge) => [edge.a, edge.b].sort().join(":") === "friday:report",
  );
  assert.ok(confirmed.strength > early.strength);
  assert.deepEqual(meetingState(26), meetingState(26));
  assert.equal(meetingState(0).links.length, 0);
  assert.equal(meetingState(0).visited.has("finance"), false);
});

test("every graph event references known nodes and a native meeting moment", () => {
  const timeline = JSON.parse(
    readFileSync(new URL("../public/demo/timeline.json", import.meta.url)),
  );
  const nativeTimes = new Set([
    0,
    42,
    ...timeline.turns.map((turn) => turn.at),
  ]);
  const ids = new Set(nodes.map((node) => node.id));
  for (const event of events) {
    assert.ok(nativeTimes.has(event.at));
    [
      ...event.focus,
      ...event.edges.flat(),
      ...(event.open ?? []),
      ...(event.resolved ?? []),
    ].forEach((id) => assert.ok(ids.has(id), id));
  }
  assert.equal(timeline.turns.length, 8);
  assert.equal(currentTurn(timeline, 3), null);
  assert.match(currentTurn(timeline, 35).text, /this afternoon/);
  assert.match(currentTurn(timeline, 10).text, /Wednesday/);
});
