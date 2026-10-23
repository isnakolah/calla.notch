import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import {
  THREE,
  createStage,
  makeNeuron,
  makeConnection,
} from "./neural-scene.js";
import {
  graphNodes,
  graphEdges,
  clusters,
  nodeById,
  sourceById,
  relatedNodes,
} from "./graph-data.js";

const $ = (s) => document.querySelector(s);
const element = (tag, text, className) => {
  const el = document.createElement(tag);
  if (text !== undefined) el.textContent = text;
  if (className) el.className = className;
  return el;
};

export function createExplorer({ selectedId, onWatch }) {
  const mount = $("#explorer-stage"),
    labels = $("#explorer-labels"),
    search = $("#graph-search"),
    filter = $("#graph-type"),
    results = $("#graph-results"),
    detail = $("#graph-detail");
  let stage,
    controls,
    frameId = 0,
    selected = null,
    matching = new Set(graphNodes.map((n) => n.id)),
    neighborhood = null,
    focusTarget = null,
    lastRender = 0,
    started = performance.now(),
    auto = true,
    introActive = true;
  const reduced = matchMedia("(prefers-reduced-motion: reduce)"),
    neurons = new Map(),
    connections = [];
  labels.replaceChildren();
  search.value = "";
  filter.value = "";
  function pick(id, move = true) {
    const node = nodeById.get(id);
    if (!node) return;
    selected = id;
    neighborhood = relatedNodes(id);
    auto = false;
    if (controls) controls.autoRotate = false;
    if (move && neurons.has(id))
      focusTarget = neurons
        .get(id)
        .neuron.position.clone()
        .multiplyScalar(0.55);
    detail.replaceChildren();
    const kicker = element(
      "p",
      `${node.type} / ${clusters[node.cluster].label}`,
      "inspector-kicker",
    );
    kicker.style.color = clusters[node.cluster].color;
    detail.append(
      kicker,
      element("h3", node.label),
      element("p", node.description, "node-description"),
    );
    const edges = graphEdges.filter((e) => e.a === id || e.b === id);
    const connectionCount = `${edges.length} ${edges.length === 1 ? "connection" : "connections"}`;
    detail.append(element("h4", connectionCount));
    const list = element("div", undefined, "connection-list");
    for (const edge of edges) {
      const other = nodeById.get(edge.a === id ? edge.b : edge.a),
        button = element("button");
      button.type = "button";
      button.append(
        element(
          "span",
          edge.a === id ? edge.label : `${other.label} → ${edge.label}`,
        ),
        element("b", edge.a === id ? other.label : node.label),
      );
      button.addEventListener("click", () => pick(other.id));
      list.append(button);
    }
    detail.append(list, element("h4", "Follow the source"));
    // Include evidence for relationships as well as the node itself.
    const sourceIds = new Set([
      ...node.sources,
      ...edges.flatMap((e) => e.sources),
    ]);
    for (const sourceId of sourceIds) {
      const source = sourceById.get(sourceId),
        article = element("article", undefined, "source-card");
      article.append(
        element("span", source.kind, "source-kind"),
        element("h5", source.title),
        element(
          "blockquote",
          `${source.speaker ? source.speaker + ": " : ""}${source.excerpt}`,
        ),
      );
      if (source.at !== undefined) {
        const button = element(
          "button",
          `Watch this moment ↗  0:${String(source.at).padStart(2, "0")}`,
          "source-watch",
        );
        button.type = "button";
        button.addEventListener("click", () => onWatch(source.at));
        article.append(button);
      }
      detail.append(article);
    }
    $("#graph-selection-status").textContent =
      `${node.label}, ${connectionCount}`;
    stage?.invalidate();
    updateLabels();
  }
  function updateResults() {
    const q = search.value.trim().toLowerCase(),
      type = filter.value;
    const matches = graphNodes.filter(
      (n) =>
        (!type || n.type === type) &&
        (!q ||
          `${n.label} ${n.type} ${n.description} ${clusters[n.cluster].label}`
            .toLowerCase()
            .includes(q)),
    );
    matching = new Set(matches.map((n) => n.id));
    results.replaceChildren();
    $("#graph-result-count").textContent =
      `${matches.length} ${matches.length === 1 ? "connection point" : "connection points"}`;
    for (const node of matches) {
      const button = element("button");
      button.type = "button";
      button.style.setProperty("--node-color", clusters[node.cluster].color);
      button.append(element("span", node.label), element("small", node.type));
      button.addEventListener("click", () => pick(node.id));
      results.append(button);
    }
    if (!matches.length)
      results.append(
        element(
          "p",
          "No matches. Try a person, project or document.",
          "empty-results",
        ),
      );
    if (q || type) {
      auto = false;
      if (controls) controls.autoRotate = false;
    }
    if (q && matches.length === 1) pick(matches[0].id);
    stage?.invalidate();
  }
  const types = [...new Set(graphNodes.map((n) => n.type))].sort();
  filter.replaceChildren(element("option", "All types"));
  filter.firstChild.value = "";
  types.forEach((type) => {
    const option = element("option", type);
    option.value = type;
    filter.append(option);
  });
  search.addEventListener("input", updateResults);
  filter.addEventListener("change", updateResults);
  updateResults();
  function updateLabels() {
    if (!stage) return;
    const bounds = mount.getBoundingClientRect(),
      occupied = [];
    const ordered = [...neurons.values()].sort(
      (a, b) =>
        (b.node.id === selected
          ? 100
          : b.node.type === "Project"
            ? 20
            : neighborhood?.has(b.node.id)
              ? 10
              : 0) -
        (a.node.id === selected
          ? 100
          : a.node.type === "Project"
            ? 20
            : neighborhood?.has(a.node.id)
              ? 10
              : 0),
    );
    let count = 0;
    for (const { node, neuron, label } of ordered) {
      const p = stage.project(neuron),
        isSelected = node.id === selected,
        important =
          isSelected ||
          node.type === "Project" ||
          neighborhood?.has(node.id) ||
          (search.value.trim() && matching.has(node.id));
      const x = p.x - bounds.left + 10,
        y = p.y - bounds.top - 8;
      let visible =
        important &&
        matching.has(node.id) &&
        p.z < 1 &&
        x > 8 &&
        y > 8 &&
        x < bounds.width - 130 &&
        y < bounds.height - 35 &&
        count < (innerWidth < 760 ? 5 : 11);
      if (
        !isSelected &&
        occupied.some((o) => Math.abs(x - o.x) < 145 && Math.abs(y - o.y) < 34)
      )
        visible = false;
      label.hidden = !visible;
      label.classList.toggle("selected", isSelected);
      if (visible) {
        count++;
        occupied.push({ x, y });
        label.style.transform = `translate(${x}px,${y}px)`;
      }
    }
  }
  try {
    stage = createStage(mount);
    stage.camera.position.set(0.3, 1.6, 18);
    stage.bloom.strength = 0.9;
    controls = new OrbitControls(stage.camera, stage.renderer.domElement);
    controls.enableDamping = !reduced.matches;
    controls.dampingFactor = 0.065;
    controls.minDistance = 4;
    controls.maxDistance = 30;
    controls.autoRotate = !reduced.matches;
    controls.autoRotateSpeed = 0.22;
    controls.target.set(0, -0.35, 0);
    controls.update();
    controls.addEventListener("change", () => stage.invalidate());
    controls.addEventListener("start", () => {
      auto = false;
      introActive = false;
      controls.autoRotate = false;
      focusTarget = null;
    });
    const group = new THREE.Group();
    stage.scene.add(group);
    for (const node of graphNodes) {
      const neuron = makeNeuron(
        new THREE.Vector3(...node.graphPosition),
        clusters[node.cluster].color,
        stage.texture,
        0.09,
      );
      neuron.userData.core.userData.nodeId = node.id;
      group.add(neuron);
      const label = element("button", node.label, "graph-node-label");
      label.type = "button";
      label.setAttribute("aria-label", `Inspect ${node.label}`);
      label.style.setProperty("--node-color", clusters[node.cluster].color);
      label.addEventListener("click", () => pick(node.id));
      labels.append(label);
      neurons.set(node.id, { node, neuron, label });
    }
    graphEdges.forEach((edge, i) => {
      const color = clusters[nodeById.get(edge.a).cluster].color,
        c = makeConnection(
          neurons.get(edge.a).neuron.position,
          neurons.get(edge.b).neuron.position,
          color,
          stage.texture,
          i,
        );
      group.add(c.line, c.pulse);
      connections.push({ ...c, edge, index: i });
    });
    // A sparse star field gives depth without competing with the meaningful graph.
    const stars = [];
    for (let i = 0; i < 110; i++)
      stars.push(
        Math.sin(i * 12.3) * 14,
        Math.cos(i * 8.9) * 9,
        -5 - Math.abs(Math.sin(i * 1.2)) * 7,
      );
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(stars, 3));
    group.add(
      new THREE.Points(
        g,
        new THREE.PointsMaterial({
          color: 0x507e96,
          size: 0.035,
          transparent: true,
          opacity: 0.35,
        }),
      ),
    );
    const raycaster = new THREE.Raycaster(),
      pointer = new THREE.Vector2();
    let down;
    stage.renderer.domElement.addEventListener("pointerdown", (e) => {
      down = { x: e.clientX, y: e.clientY };
    });
    stage.renderer.domElement.addEventListener("pointerup", (e) => {
      if (!down || Math.hypot(e.clientX - down.x, e.clientY - down.y) > 5)
        return;
      const rect = mount.getBoundingClientRect();
      pointer.set(
        ((e.clientX - rect.left) / rect.width) * 2 - 1,
        (-(e.clientY - rect.top) / rect.height) * 2 + 1,
      );
      raycaster.setFromCamera(pointer, stage.camera);
      const hit = raycaster.intersectObjects(
        [...neurons.values()]
          .filter((n) => matching.has(n.node.id))
          .map((n) => n.neuron.userData.core),
      )[0];
      if (hit) pick(hit.object.userData.nodeId);
    });
    mount.dataset.renderer = "webgl";
    function frame(now) {
      frameId = requestAnimationFrame(frame);
      if (document.hidden || now - lastRender < 1000 / 30) return;
      lastRender = now;
      if (reduced.matches && !stage.dirty) return;
      if (focusTarget)
        controls.target.lerp(focusTarget, reduced.matches ? 1 : 0.08);
      if (auto && introActive && !reduced.matches) {
        const intro = Math.min(1, (now - started) / 1800);
        stage.camera.position.z = 18 - 2 * (1 - (1 - intro) ** 3);
        if (intro >= 1) introActive = false;
      }
      controls.autoRotate = auto && !reduced.matches;
      controls.update();
      group.updateMatrixWorld(true);
      stage.camera.updateMatrixWorld();
      for (const { node, neuron } of neurons.values()) {
        const match = matching.has(node.id),
          near = !selected || neighborhood.has(node.id),
          opacity = match ? (near ? 1 : 0.18) : 0.05;
        neuron.userData.material.opacity = opacity;
        neuron.userData.dendrites.material.opacity = opacity * 0.65;
        neuron.userData.core.scale.setScalar(
          node.id === selected ? 0.42 : node.type === "Project" ? 0.32 : 0.22,
        );
      }
      for (const item of connections) {
        const match = matching.has(item.edge.a) && matching.has(item.edge.b),
          near =
            !selected || item.edge.a === selected || item.edge.b === selected;
        item.line.material.opacity = match
          ? near
            ? selected
              ? 0.65
              : 0.26
            : 0.065
          : 0.025;
        item.pulse.visible = match && near && !reduced.matches;
        item.pulse.position.copy(
          item.curve.getPoint((now * 0.00013 + item.index * 0.137) % 1),
        );
      }
      updateLabels();
      stage.render();
    }
    stage.renderer.domElement.addEventListener("webglcontextlost", (e) => {
      if (stage.disposed) return;
      e.preventDefault();
      cancelAnimationFrame(frameId);
      stage.renderer.domElement.hidden = true;
      labels.hidden = true;
      mount.dataset.renderer = "fallback";
      document
        .querySelectorAll("[data-zoom]")
        .forEach((b) => (b.disabled = true));
      $("#explorer-fallback").hidden = false;
    });
    frameId = requestAnimationFrame(frame);
  } catch {
    stage?.dispose();
    stage = null;
    mount.dataset.renderer = "fallback";
    document
      .querySelectorAll("[data-zoom]")
      .forEach((b) => (b.disabled = true));
    $("#explorer-fallback").hidden = false;
  }
  document
    .querySelectorAll("[data-zoom]")
    .forEach((b) => (b.disabled = !stage));
  const reset = () => {
    selected = null;
    neighborhood = null;
    focusTarget = null;
    auto = true;
    introActive = true;
    started = performance.now();
    search.value = "";
    filter.value = "";
    if (controls) {
      stage.camera.position.set(0.3, 1.6, 18);
      controls.target.set(0, -0.35, 0);
      controls.update();
    }
    detail.replaceChildren(
      element("p", "SELECT A CONNECTION", "inspector-kicker"),
      element("h3", "Every point has a story."),
      element(
        "p",
        "Follow a person, project or decision back to the conversation behind it.",
        "node-description",
      ),
    );
    updateResults();
  };
  const zoom = (e) => {
    if (!controls) return;
    auto = false;
    controls.autoRotate = false;
    const direction = e.currentTarget.dataset.zoom === "in" ? 0.8 : 1.25,
      offset = stage.camera.position.clone().sub(controls.target);
    offset.setLength(THREE.MathUtils.clamp(offset.length() * direction, 4, 30));
    stage.camera.position.copy(controls.target).add(offset);
    controls.update();
  };
  $("#graph-reset").addEventListener("click", reset);
  document
    .querySelectorAll("[data-zoom]")
    .forEach((b) => b.addEventListener("click", zoom));
  if (selectedId) pick(selectedId, false);
  else reset();
  return {
    dispose() {
      cancelAnimationFrame(frameId);
      search.removeEventListener("input", updateResults);
      filter.removeEventListener("change", updateResults);
      $("#graph-reset").removeEventListener("click", reset);
      document
        .querySelectorAll("[data-zoom]")
        .forEach((b) => b.removeEventListener("click", zoom));
      controls?.dispose();
      stage?.dispose();
      labels.replaceChildren();
    },
  };
}
