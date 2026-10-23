import test from "node:test";
import assert from "node:assert/strict";
import {
  graphNodes,
  graphEdges,
  sources,
  nativeTimeline,
  captures,
  storyState,
  edgeKey,
  relatedNodes,
} from "../src/graph-data.js";

test("the fictional company graph is connected, spatial and fully sourced", () => {
  assert.equal(graphNodes.length, 40);
  const ids = new Set(graphNodes.map((n) => n.id)),
    sourceIds = new Set(sources.map((s) => s.id));
  assert.equal(ids.size, graphNodes.length);
  assert.equal(new Set(graphEdges.map((e) => e.id)).size, graphEdges.length);
  for (const node of graphNodes) {
    assert.ok(node.sources.length, node.id);
    node.sources.forEach((id) => assert.ok(sourceIds.has(id), id));
    assert.equal(node.graphPosition.length, 3);
    assert.ok(node.graphPosition.every(Number.isFinite));
  }
  for (const edge of graphEdges) {
    assert.ok(ids.has(edge.a) && ids.has(edge.b), edge.id);
    assert.notEqual(edge.a, edge.b);
    assert.ok(edge.label);
    assert.ok(edge.sources.length);
    edge.sources.forEach((id) => assert.ok(sourceIds.has(id), id));
  }
  const reached = new Set(["meeting"]);
  for (let pass = 0; pass < graphNodes.length; pass++)
    for (const e of graphEdges)
      if (reached.has(e.a) || reached.has(e.b)) {
        reached.add(e.a);
        reached.add(e.b);
      }
  assert.equal(reached.size, graphNodes.length);
  for (const cluster of ["reporting", "launch", "planning"])
    assert.ok(
      new Set(
        graphNodes
          .filter((n) => n.cluster === cluster)
          .map((n) => n.graphPosition[2]),
      ).size > 5,
    );
  assert.ok(relatedNodes("maya").has("review"));
  assert.ok(relatedNodes("maya").has("estimate"));
});

test("every animated capture follows the actual native summary and has graph evidence", () => {
  assert.equal(captures.length, nativeTimeline.turns.length);
  captures.forEach((capture, i) => {
    assert.equal(capture.at, nativeTimeline.turns[i].at);
    assert.equal(capture.summaryAt, nativeTimeline.summaries[i].at);
    assert.ok(
      capture.at < capture.summaryAt && capture.summaryAt < capture.arrivalAt,
    );
    const source = sources.find((s) => s.id === `native-${capture.at}`);
    assert.equal(source.excerpt, nativeTimeline.turns[i].text);
    capture.edges.forEach(([a, b]) =>
      assert.ok(graphEdges.some((e) => e.id === edgeKey(a, b))),
    );
    assert.ok(capture.arrivalAt + 1.1 < (captures[i + 1]?.at ?? 45));
  });
});

test("capture, notch update, arrival, neuron formation and linking happen in order", () => {
  assert.equal(storyState(4.3).phase, "capture");
  assert.equal(storyState(5.2).phase, "understanding");
  assert.equal(storyState(6.2).phase, "transfer");
  assert.equal(storyState(6.64).visited.has("report"), false);
  assert.equal(storyState(6.7).visited.has("report"), true);
  assert.equal(storyState(6.7).phase, "forming");
  assert.equal(storyState(7.3).phase, "linking");
  assert.equal(storyState(7.9).phase, "connected");
  assert.equal(storyState(6.7).births.get("report"), 6.65);
  assert.ok(storyState(44).links.length > 0);
  assert.equal(storyState(44).capture.at, 39);
});

test("seeking reconstructs dependencies and confirmations without accumulating changes", () => {
  assert.ok(storyState(27).open.has("finance"));
  assert.ok(storyState(37.4).open.has("finance"));
  assert.equal(storyState(37.8).open.has("finance"), false);
  const key = edgeKey("report", "friday"),
    strength = (t) =>
      storyState(t).links.find((e) => edgeKey(e.a, e.b) === key)?.strength;
  assert.ok(strength(44) > strength(7.9));
  const first = storyState(27);
  storyState(45);
  storyState(0);
  assert.deepEqual(storyState(27), first);
  assert.equal(storyState(0).links.length, 0);
  assert.equal(storyState(5).visited.has("finance"), false);
  assert.deepEqual(storyState(NaN), storyState(0));
  assert.deepEqual(storyState(100), storyState(45));
});
