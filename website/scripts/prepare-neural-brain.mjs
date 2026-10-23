/** Bake anatomical fold contours and surface routes; no geometry work at runtime.
 * Source: scripts/smooth-brain.py (the attributed HRA cortex).
 */
import { readFileSync, writeFileSync } from "node:fs";
import * as THREE from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { MeshoptSimplifier } from "meshoptimizer";
import { graphNodes, graphEdges } from "../src/graph-data.js";
const root = new URL("../", import.meta.url);
const input = readFileSync(new URL(".data/brain-smooth.glb", root));
const gltf = await new GLTFLoader().parseAsync(
  input.buffer.slice(input.byteOffset, input.byteOffset + input.byteLength),
  "",
);
let source;
gltf.scene.updateMatrixWorld(true);
gltf.scene.traverse((o) => {
  if (o.isMesh) source = o.geometry.clone().applyMatrix4(o.matrixWorld);
});
await MeshoptSimplifier.ready;
const [simplified] = MeshoptSimplifier.simplify(
  new Uint32Array(source.index.array),
  source.attributes.position.array,
  3,
  180000,
  0.002,
);
const used = new Map(),
  coords = [],
  idx = [];
for (const old of simplified) {
  if (!used.has(old)) {
    used.set(old, used.size);
    coords.push(
      ...source.attributes.position.array.slice(old * 3, old * 3 + 3),
    );
  }
  idx.push(used.get(old));
}
const geometry = new THREE.BufferGeometry();
geometry.setAttribute("position", new THREE.Float32BufferAttribute(coords, 3));
geometry.setIndex(idx);
geometry.computeBoundingBox();
const center = geometry.boundingBox.getCenter(new THREE.Vector3()),
  size = geometry.boundingBox.getSize(new THREE.Vector3());
geometry.translate(-center.x, -center.y, -center.z);
geometry.scale(...Array(3).fill(3.5 / Math.max(size.x, size.y, size.z)));
geometry.rotateY(-1.05);
geometry.computeVertexNormals();
const pos = geometry.attributes.position.array,
  norm = geometry.attributes.normal.array,
  indices = geometry.index.array,
  n = pos.length / 3;
const neighbors = Array.from({ length: n }, () => new Set());
for (let i = 0; i < indices.length; i += 3) {
  const a = indices[i],
    b = indices[i + 1],
    c = indices[i + 2];
  for (const [u, v] of [
    [a, b],
    [b, c],
    [c, a],
  ]) {
    neighbors[u].add(v);
    neighbors[v].add(u);
  }
}
const point = (i, lift = 0) =>
  [0, 1, 2].map((k) => pos[i * 3 + k] + norm[i * 3 + k] * lift);
const distance = (a, b) =>
  Math.hypot(...[0, 1, 2].map((k) => pos[a * 3 + k] - pos[b * 3 + k]));
let curvature = Float32Array.from({ length: n }, (_, i) => {
  let delta = [0, 0, 0],
    length = 0;
  for (const j of neighbors[i]) {
    for (let k = 0; k < 3; k++) delta[k] += pos[j * 3 + k] - pos[i * 3 + k];
    length += distance(i, j);
  }
  return (
    Math.abs(delta.reduce((s, v, k) => s + v * norm[i * 3 + k], 0)) /
    Math.max(0.00001, length)
  );
});
for (let pass = 0; pass < 3; pass++)
  curvature = Float32Array.from(
    curvature,
    (value, i) =>
      (value * 2 + [...neighbors[i]].reduce((s, j) => s + curvature[j], 0)) /
      (neighbors[i].size + 2),
  );
const sorted = [...curvature].sort((a, b) => a - b),
  levels = [0.2, 0.38, 0.55, 0.7, 0.82, 0.91].map(
    (q) => sorted[Math.floor(q * n)],
  );
const max = sorted[Math.floor(n * 0.96)],
  contours = [],
  slices = [];
function segments(values, level, out) {
  for (let j = 0; j < indices.length; j += 3) {
    const triangle = [indices[j], indices[j + 1], indices[j + 2]],
      cross = [];
    for (let k = 0; k < 3; k++) {
      const a = triangle[k],
        b = triangle[(k + 1) % 3],
        va = values[a],
        vb = values[b];
      if (va < level === vb < level) continue;
      const t = (level - va) / (vb - va),
        pa = point(a, 0.006),
        pb = point(b, 0.006);
      cross.push(pa.map((v, c) => v + (pb[c] - v) * t));
    }
    if (cross.length === 2) out.push(...cross[0], ...cross[1]);
  }
}
for (const level of levels) segments(curvature, level, contours);
const heights = Float32Array.from(
  { length: n },
  (_, i) => pos[i * 3 + 1] + pos[i * 3] * 0.16,
);
for (let y = -1.7; y < 1.7; y += 0.055) segments(heights, y, slices);
// Distribute knowledge around both hemispheres, including the rear cortex.
// These are visual placements, not biological or functional brain mappings.
const mesh = new THREE.Mesh(
  geometry,
  new THREE.MeshBasicMaterial({ side: THREE.DoubleSide }),
);
mesh.updateMatrixWorld(true);
const ray = new THREE.Raycaster(),
  anchors = {},
  occupiedAnchors = [];
const storyAngles = {
  meeting: [-0.25, 0.55],
  report: [0, 0.2],
  friday: [0.45, 0.5],
  you: [0.85, 0.05],
  draft: [1.2, 0.35],
  maya: [2.05, 0.15],
  review: [2.55, 0.45],
  template: [-2.05, 0.4],
  finance: [-1.25, -0.08],
};
for (const [nodeIndex, node] of graphNodes.entries()) {
  const [longitude, latitude] = storyAngles[node.id] ?? [
    nodeIndex * 2.39996323,
    0.05 + (nodeIndex % 7) * 0.11,
  ];
  const direction = new THREE.Vector3(
    Math.sin(longitude) * Math.cos(latitude),
    Math.sin(latitude),
    Math.cos(longitude) * Math.cos(latitude),
  );
  ray.set(direction.clone().multiplyScalar(5), direction.clone().negate());
  const hit = ray.intersectObject(mesh)[0];
  let vertex;
  if (hit) {
    const f = hit.face;
    vertex = [f.a, f.b, f.c].sort(
      (a, b) =>
        new THREE.Vector3(...point(a)).distanceToSquared(hit.point) -
        new THREE.Vector3(...point(b)).distanceToSquared(hit.point),
    )[0];
  } else {
    throw Error(`Cortical anchor ray missed ${node.id}`);
  }
  const wanted = point(vertex);
  let distinct = vertex,
    bestDistinct = Infinity;
  for (let j = 0; j < n; j++) {
    const p = point(j),
      d = p.reduce((sum, v, k) => sum + (v - wanted[k]) ** 2, 0);
    if (
      d >= bestDistinct ||
      occupiedAnchors.some(
        (q) => p.reduce((sum, v, k) => sum + (v - q[k]) ** 2, 0) < 0.0144,
      )
    )
      continue;
    distinct = j;
    bestDistinct = d;
  }
  vertex = distinct;
  occupiedAnchors.push(point(vertex));
  anchors[node.id] = {
    vertex,
    position: point(vertex, 0.025),
    normal: [...norm.slice(vertex * 3, vertex * 3 + 3)],
  };
}
class Heap {
  a = [];
  push(item) {
    let i = this.a.length;
    this.a.push(item);
    while (i) {
      const p = (i - 1) >> 1;
      if (this.a[p][0] <= item[0]) break;
      this.a[i] = this.a[p];
      i = p;
    }
    this.a[i] = item;
  }
  pop() {
    const first = this.a[0],
      last = this.a.pop();
    if (this.a.length) {
      let i = 0;
      while (i * 2 + 1 < this.a.length) {
        let c = i * 2 + 1;
        if (c + 1 < this.a.length && this.a[c + 1][0] < this.a[c][0]) c++;
        if (this.a[c][0] >= last[0]) break;
        this.a[i] = this.a[c];
        i = c;
      }
      this.a[i] = last;
    }
    return first;
  }
}
const trees = new Map();
function tree(start) {
  if (trees.has(start)) return trees.get(start);
  const d = new Float64Array(n).fill(Infinity),
    prev = new Int32Array(n).fill(-1),
    heap = new Heap();
  d[start] = 0;
  heap.push([0, start]);
  while (heap.a.length) {
    const [cost, u] = heap.pop();
    if (cost > d[u]) continue;
    for (const v of neighbors[u]) {
      const weight =
        distance(u, v) *
        (1.5 - 0.65 * Math.min(1, (curvature[u] + curvature[v]) / (2 * max)));
      const next = cost + weight;
      if (next < d[v]) {
        d[v] = next;
        prev[v] = u;
        heap.push([next, v]);
      }
    }
  }
  trees.set(start, prev);
  return prev;
}
const paths = {};
for (const edge of graphEdges) {
  const a = anchors[edge.a].vertex,
    b = anchors[edge.b].vertex,
    prev = tree(a),
    route = [b];
  let i = b;
  while (i !== a) {
    i = prev[i];
    if (i < 0) throw Error(`Disconnected cortex: ${edge.id}`);
    route.push(i);
    if (route.length > n) throw Error("Cycle");
  }
  paths[edge.id] = route.reverse().map((i) => point(i, 0.025));
}
const round = (x) => Number(x.toFixed(4));
// Separate buffers keep the startup JSON small and the surface locally hosted.
const packed = Buffer.concat([
  Buffer.from(pos.buffer, pos.byteOffset, pos.byteLength),
  Buffer.from(norm.buffer, norm.byteOffset, norm.byteLength),
  Buffer.from(new Uint32Array(indices).buffer),
]);
writeFileSync(new URL("public/models/cortex.bin", root), packed);
writeFileSync(
  new URL("public/models/cortex.json", root),
  JSON.stringify({
    vertices: n,
    indices: indices.length,
    source: "HRA Brain Male v1.3; continuous cortex reconstruction",
    license: "CC BY 4.0",
  }),
);
const lines = Float32Array.from([...contours, ...slices]);
writeFileSync(
  new URL("public/models/neural-folds.bin", root),
  Buffer.from(lines.buffer),
);
writeFileSync(
  new URL("public/models/neural-paths.json", root),
  JSON.stringify({
    contourVertices: contours.length / 3,
    sliceVertices: slices.length / 3,
    anchors: Object.fromEntries(
      Object.entries(anchors).map(([id, a]) => [
        id,
        { position: a.position.map(round), normal: a.normal.map(round) },
      ]),
    ),
    paths: Object.fromEntries(
      Object.entries(paths).map(([id, p]) => [id, p.map((v) => v.map(round))]),
    ),
  }),
);
console.log({
  vertices: n,
  faces: indices.length / 3,
  contourSegments: contours.length / 6,
  sliceSegments: slices.length / 6,
  paths: Object.keys(paths).length,
  surfaceBytes: packed.length,
  threadBytes: lines.byteLength,
});
