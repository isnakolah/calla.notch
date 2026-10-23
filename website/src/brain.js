import { THREE, createStage } from "./neural-scene.js";
import { graphNodes, graphEdges, storyState, edgeKey } from "./graph-data.js";
import { brainMotion } from "./brain-motion.js";

export function brainFallback(container) {
  container.dataset.renderer = "fallback";
  const fallback = document.querySelector("#brain-fallback");
  fallback.hidden = false;
  const img = document.createElement("img");
  img.src = "/models/brain-neural-fallback.jpg";
  img.alt =
    "An anatomical brain with folded neural pathways connecting knowledge.";
  fallback.replaceChildren(img);
}
const load = async (url, type = "json") => {
  const r = await fetch(url);
  if (!r.ok) throw Error(`Could not load ${url}`);
  return type === "json" ? r.json() : r.arrayBuffer();
};
export async function createBrain(container, labelRoot, getPlayback, onSelect) {
  let stage;
  try {
    stage = createStage(container);
  } catch {
    brainFallback(container);
    return {
      update() {},
      focusPoint() {
        return null;
      },
    };
  }
  let meta, buffer, network, foldBuffer;
  try {
    [meta, buffer, network, foldBuffer] = await Promise.all([
      load("/models/cortex.json"),
      load("/models/cortex.bin", "buffer"),
      load("/models/neural-paths.json"),
      load("/models/neural-folds.bin", "buffer"),
    ]);
  } catch {
    stage.dispose();
    brainFallback(container);
    return {
      update() {},
      focusPoint() {
        return null;
      },
    };
  }
  const group = new THREE.Group();
  stage.scene.add(group);
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute(
    "position",
    new THREE.BufferAttribute(
      new Float32Array(buffer, 0, meta.vertices * 3),
      3,
    ),
  );
  geometry.setAttribute(
    "normal",
    new THREE.BufferAttribute(
      new Float32Array(buffer, meta.vertices * 12, meta.vertices * 3),
      3,
    ),
  );
  geometry.setIndex(
    new THREE.BufferAttribute(
      new Uint32Array(buffer, meta.vertices * 24, meta.indices),
      1,
    ),
  );
  const cortex = new THREE.Mesh(
    geometry,
    new THREE.MeshStandardMaterial({
      color: 0x102c32,
      roughness: 0.82,
      metalness: 0.12,
      emissive: 0x04151b,
      emissiveIntensity: 0.3,
    }),
  );
  group.add(cortex);
  stage.scene.add(new THREE.HemisphereLight(0xb6e8e5, 0x01060a, 1.1));
  const key = new THREE.DirectionalLight(0x9fe6e4, 2.3);
  key.position.set(-3, 4, 5);
  stage.scene.add(key);
  const rim = new THREE.DirectionalLight(0x4288bb, 1.5);
  rim.position.set(3, 1, -2);
  stage.scene.add(rim);
  stage.bloom.strength = 0.38;
  stage.bloom.radius = 0.35;
  stage.bloom.threshold = 0.7;
  const folds = new Float32Array(foldBuffer);
  function lineLayer(array, color, opacity) {
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.BufferAttribute(array, 3));
    const lines = new THREE.LineSegments(
      g,
      new THREE.LineBasicMaterial({
        color,
        transparent: true,
        opacity,
        depthWrite: false,
      }),
    );
    group.add(lines);
    return lines;
  }
  lineLayer(folds.subarray(0, network.contourVertices * 3), 0x8ccac5, 0.36);
  lineLayer(folds.subarray(network.contourVertices * 3), 0x529a9f, 0.15);
  // Fine cells rest on the folded cortex; meaningful knowledge uses brighter nodes.
  const fine = [];
  for (let i = 0; i < network.contourVertices; i += 19)
    fine.push(...folds.subarray(i * 3, i * 3 + 3));
  const fineGeometry = new THREE.BufferGeometry();
  fineGeometry.setAttribute(
    "position",
    new THREE.Float32BufferAttribute(fine, 3),
  );
  group.add(
    new THREE.Points(
      fineGeometry,
      new THREE.PointsMaterial({
        color: 0xb0f0df,
        size: 0.012,
        transparent: true,
        opacity: 0.65,
        depthWrite: false,
      }),
    ),
  );
  const neurons = new Map(),
    links = new Map();
  for (const node of graphNodes) {
    const anchor = network.anchors[node.id];
    const holder = new THREE.Group();
    holder.position.fromArray(anchor.position);
    group.add(holder);
    const material = new THREE.SpriteMaterial({
      map: stage.texture,
      color: 0x9ffff0,
      transparent: true,
      depthWrite: false,
    });
    const core = new THREE.Sprite(material);
    core.scale.setScalar(0.055);
    holder.add(core);
    const halo = new THREE.Sprite(
      new THREE.SpriteMaterial({
        map: stage.texture,
        color: 0x54dfd4,
        transparent: true,
        opacity: 0.28,
        depthWrite: false,
      }),
    );
    halo.scale.setScalar(0.18);
    holder.add(halo);
    const label = document.createElement("button");
    label.className = "neuron-label";
    label.textContent = node.label;
    label.type = "button";
    label.hidden = true;
    label.setAttribute("aria-label", `Explore ${node.label}`);
    label.addEventListener("click", () => onSelect(node.id));
    labelRoot.append(label);
    neurons.set(node.id, {
      node,
      holder,
      core,
      halo,
      label,
      normal: new THREE.Vector3(...anchor.normal),
    });
  }
  for (const edge of graphEdges) {
    const points = network.paths[edge.id].map((p) => new THREE.Vector3(...p));
    const curve = new THREE.CurvePath();
    for (let i = 1; i < points.length; i++)
      curve.add(new THREE.LineCurve3(points[i - 1], points[i]));
    const g = new THREE.BufferGeometry().setFromPoints(points);
    const line = new THREE.Line(
      g,
      new THREE.LineBasicMaterial({
        color: 0x8bdad3,
        transparent: true,
        opacity: 0.3,
        depthWrite: false,
      }),
    );
    group.add(line);
    links.set(edge.id, { edge, points, curve, line });
  }
  const pulse = new THREE.Sprite(
    new THREE.SpriteMaterial({
      map: stage.texture,
      color: 0xdcfff3,
      transparent: true,
      depthTest: false,
      depthWrite: false,
    }),
  );
  pulse.scale.setScalar(0.12);
  pulse.renderOrder = 4;
  group.add(pulse);
  const trail = new THREE.Points(
    new THREE.BufferGeometry(),
    new THREE.PointsMaterial({
      color: 0xa0ffe4,
      size: 0.023,
      transparent: true,
      opacity: 0.85,
      depthTest: false,
      depthWrite: false,
    }),
  );
  trail.geometry.setAttribute(
    "position",
    new THREE.BufferAttribute(new Float32Array(18 * 3), 3),
  );
  group.add(trail);
  stage.camera.position.set(0, 0.1, 5.8);
  stage.camera.lookAt(0, 0, 0);
  const reduced = matchMedia("(prefers-reduced-motion: reduce)"),
    small = matchMedia("(max-width:760px)");
  let invalid = true,
    frameId,
    lastRender = 0,
    visible = true;
  const observer = new IntersectionObserver(
    (entries) => {
      visible = entries[0].isIntersecting;
      invalid = true;
    },
    { rootMargin: "100px" },
  );
  observer.observe(container);
  function frame(now) {
    frameId = requestAnimationFrame(frame);
    const playback = getPlayback();
    if (document.hidden || playback.exploring || !visible) return;
    if (now - lastRender < 1000 / (small.matches ? 24 : 40)) return;
    if (!playback.playing && !invalid && !stage.dirty) return;
    invalid = false;
    lastRender = now;
    const state = storyState(playback.time),
      motion = brainMotion(playback.time, network.anchors),
      meeting = playback.chapter === "meeting";
    group.rotation.set(
      reduced.matches ? 0 : motion.pitch,
      reduced.matches ? 0 : motion.yaw,
      -0.035,
    );
    group.updateMatrixWorld(true);
    stage.camera.updateMatrixWorld();
    const active = motion.edge ? links.get(motion.edge) : null;
    pulse.visible = trail.visible = Boolean(
      meeting && active && motion.pulse && !reduced.matches,
    );
    if (pulse.visible) {
      const point = active.curve.getPoint(
        active.edge.a === motion.source ? motion.progress : 1 - motion.progress,
      );
      pulse.position.copy(point);
      const positions = trail.geometry.attributes.position;
      for (let i = 0; i < 18; i++) {
        const p = active.curve.getPoint(
          active.edge.a === motion.source
            ? Math.max(0, motion.progress - i * 0.004)
            : 1 - Math.max(0, motion.progress - i * 0.004),
        );
        positions.setXYZ(i, p.x, p.y, p.z);
      }
      positions.needsUpdate = true;
    }
    const liveLinks = new Map(state.links.map((e) => [edgeKey(e.a, e.b), e]));
    for (const [id, item] of links) {
      const live = liveLinks.get(id);
      const established = [item.edge.a, item.edge.b].every((id) =>
        neurons
          .get(id)
          .node.sources.every((source) => !source.startsWith("native-")),
      );
      item.line.visible = meeting ? Boolean(live) || established : true;
      const focused = id === motion.edge;
      item.line.material.opacity = focused ? 0.85 : live ? 0.16 : 0.07;
      item.line.material.color.set(focused ? 0xaaffec : 0x53999d);
      const growth =
        focused && !reduced.matches ? Math.max(0.02, motion.progress) : 1;
      const count = Math.max(2, Math.floor(item.points.length * growth));
      const reverse = focused && motion.source !== item.edge.a;
      item.line.geometry.setDrawRange(
        reverse ? item.points.length - count : 0,
        count,
      );
    }
    const focus = motion.pulse
      ? [motion.source, motion.destination]
      : (state.capture?.focus ?? ["meeting", "template"]);
    const rect = container.getBoundingClientRect(),
      occupied = [];
    let labelCount = 0;
    for (const [id, item] of neurons) {
      const existing = item.node.sources.every(
        (source) => !source.startsWith("native-"),
      );
      const show = meeting ? state.visited.has(id) || existing : true;
      item.holder.visible = show;
      const focused = focus.includes(id),
        arrival = id === motion.destination && motion.progress > 0.9;
      item.core.scale.setScalar(focused ? 0.078 : 0.036);
      item.halo.scale.setScalar(arrival ? 0.27 : focused ? 0.19 : 0.1);
      item.core.material.color.set(state.open.has(id) ? 0xf6be80 : 0xb7fff0);
      const normal = item.normal.clone().transformDirection(group.matrixWorld),
        p = stage.project(item.holder);
      const labelVisible =
        show && focused && normal.z > -0.1 && p.z < 1 && labelCount < 3;
      item.label.hidden = !labelVisible;
      if (labelVisible) {
        labelCount++;
        let x = Math.max(
            8,
            Math.min(
              rect.width - item.label.offsetWidth - 8,
              p.x - rect.left + 14,
            ),
          ),
          y = p.y - rect.top - 12;
        for (const prior of occupied)
          if (Math.abs(y - prior.y) < 36 && Math.abs(x - prior.x) < 150)
            y = prior.y + 36;
        y = Math.max(8, Math.min(rect.height - 40, y));
        occupied.push({ x, y });
        item.label.style.transform = `translate(${x}px,${y}px)`;
      }
    }
    container.dataset.phase = state.phase;
    container.dataset.nodeCount = String(state.visited.size);
    container.dataset.activeConnection = motion.edge || "";
    stage.render();
    document.querySelector("#brain-fallback").hidden = true;
  }
  function update() {
    invalid = true;
  }
  function lost(e) {
    if (stage.disposed) return;
    e.preventDefault();
    cancelAnimationFrame(frameId);
    stage.renderer.domElement.hidden = true;
    labelRoot.hidden = true;
    brainFallback(container);
  }
  stage.renderer.domElement.addEventListener("webglcontextlost", lost);
  document.addEventListener("visibilitychange", update);
  reduced.addEventListener("change", update);
  container.dataset.renderer = "webgl";
  frameId = requestAnimationFrame(frame);
  return {
    update,
    focusPoint(id) {
      const item = neurons.get(id);
      return item ? stage.project(item.holder) : null;
    },
    dispose() {
      cancelAnimationFrame(frameId);
      observer.disconnect();
      document.removeEventListener("visibilitychange", update);
      reduced.removeEventListener("change", update);
      neurons.forEach((n) => n.label.remove());
      stage.dispose();
    },
  };
}
