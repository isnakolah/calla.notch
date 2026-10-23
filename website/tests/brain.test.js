import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { brainMotion } from "../src/brain-motion.js";
import { captures, graphNodes, graphEdges } from "../src/graph-data.js";
const asset = (name) => new URL(`../public/models/${name}`, import.meta.url);
const network = JSON.parse(readFileSync(asset("neural-paths.json")));
const meta = JSON.parse(readFileSync(asset("cortex.json")));

test("baked cortical paths connect the correct knowledge anchors with short surface steps", () => {
  for (const node of graphNodes) {
    const anchor = network.anchors[node.id];
    assert.ok(anchor, node.id);
    assert.ok(anchor.position.every(Number.isFinite));
    assert.ok(Math.abs(Math.hypot(...anchor.normal) - 1) < 0.002);
  }
  for (const edge of graphEdges) {
    const path = network.paths[edge.id];
    assert.ok(path.length >= 2, edge.id);
    assert.deepEqual(path[0], network.anchors[edge.a].position);
    assert.deepEqual(path.at(-1), network.anchors[edge.b].position);
    for (let i = 1; i < path.length; i++) {
      assert.ok(path[i].every(Number.isFinite));
      const step = Math.hypot(...path[i].map((v, k) => v - path[i - 1][k]));
      assert.ok(step < 0.18, `${edge.id}: ${step}`);
    }
  }
  assert.equal(
    readFileSync(asset("cortex.bin")).byteLength,
    meta.vertices * 24 + meta.indices * 4,
  );
  assert.equal(
    readFileSync(asset("neural-folds.bin")).byteLength,
    (network.contourVertices + network.sliceVertices) * 12,
  );
});

test("brain choreography follows native arrival, with visible travel across both hemispheres", () => {
  assert.equal(brainMotion(captures[0].arrivalAt, network.anchors).edge, null);
  for (const c of captures) {
    const state = brainMotion(c.arrivalAt + 0.8, network.anchors);
    assert.ok(network.paths[state.edge]);
    assert.ok(state.pulse);
    assert.ok(state.progress > 0 && state.progress < 1);
    assert.ok(
      c.focus.includes(state.destination) ||
        c.edges.some((pair) => pair.includes(state.destination)),
    );
  }
  for (let t = 0; t <= 45; t += 0.05) {
    const state = brainMotion(t, network.anchors);
    assert.ok(Number.isFinite(state.yaw));
    assert.ok(Number.isFinite(state.pitch) && Math.abs(state.pitch) <= 0.16);
  }
});

test("pause, backward seeking and loop boundary reproduce camera and signal state", () => {
  const state = brainMotion(8, network.anchors);
  brainMotion(42, network.anchors);
  brainMotion(0, network.anchors);
  assert.deepEqual(brainMotion(8, network.anchors), state);
  assert.deepEqual(
    brainMotion(8, network.anchors),
    brainMotion(8, network.anchors),
  );
  const end = brainMotion(45, network.anchors);
  assert.ok(Math.abs(Math.sin(end.yaw)) < 0.00001);
  assert.ok(Math.cos(end.yaw) > 0.99999);
  assert.equal(Math.abs(end.pitch), 0);
  assert.deepEqual(
    brainMotion(NaN, network.anchors),
    brainMotion(0, network.anchors),
  );
});

test("knowledge anchors and camera views cover the front and back of both hemispheres", () => {
  const anchors = Object.values(network.anchors);
  for (const x of [-1, 1])
    for (const z of [-1, 1])
      assert.ok(
        anchors.some((a) => a.position[0] * x > 0.3 && a.position[2] * z > 0.3),
      );
  const views = captures.map(
    (c) => brainMotion(c.arrivalAt + 2.9, network.anchors).yaw,
  );
  assert.ok(
    views.some((y) => Math.cos(y) < 0),
    "The opposite side is revealed during playback",
  );
  let previous = brainMotion(0, network.anchors).yaw;
  for (let t = 0.02; t <= 45; t += 0.02) {
    const yaw = brainMotion(t, network.anchors).yaw;
    assert.ok(Math.abs(yaw - previous) < 0.09, "No sudden camera spin");
    previous = yaw;
  }
});
