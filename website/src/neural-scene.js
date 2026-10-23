import * as THREE from "three";
import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
import { OutputPass } from "three/addons/postprocessing/OutputPass.js";
export { THREE };
export function seeded(seed = 731) {
  return () => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 4294967296;
  };
}
export function glowTexture() {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 64;
  const ctx = canvas.getContext("2d"),
    g = ctx.createRadialGradient(32, 32, 0, 32, 32, 32);
  g.addColorStop(0, "#ffffff");
  g.addColorStop(0.1, "#ffffff");
  g.addColorStop(0.25, "#ffffff88");
  g.addColorStop(1, "#ffffff00");
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 64, 64);
  return new THREE.CanvasTexture(canvas);
}
export function createStage(container) {
  const renderer = new THREE.WebGLRenderer({
    alpha: true,
    antialias: true,
    powerPreference: "low-power",
  });
  renderer.setPixelRatio(
    Math.min(devicePixelRatio, innerWidth < 760 ? 1.25 : 1.5),
  );
  renderer.setClearColor(0x030910, 0);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.1;
  container.prepend(renderer.domElement);
  const scene = new THREE.Scene(),
    camera = new THREE.PerspectiveCamera(36, 1, 0.1, 100);
  camera.position.set(0, 0, 8);
  const composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(
    new THREE.Vector2(600, 500),
    0.75,
    0.55,
    0.25,
  );
  composer.addPass(bloom);
  const output = new OutputPass();
  composer.addPass(output);
  let rect,
    dirty = true,
    disposed = false;
  function resize() {
    rect = container.getBoundingClientRect();
    if (!rect.width || !rect.height) return;
    renderer.setSize(rect.width, rect.height, false);
    composer.setSize(rect.width, rect.height);
    camera.aspect = rect.width / rect.height;
    camera.updateProjectionMatrix();
    dirty = true;
  }
  const observer = new ResizeObserver(resize);
  observer.observe(container);
  resize();
  const texture = glowTexture();
  return {
    renderer,
    scene,
    camera,
    composer,
    texture,
    bloom,
    get dirty() {
      return dirty;
    },
    get disposed() {
      return disposed;
    },
    invalidate() {
      dirty = true;
    },
    render() {
      composer.render();
      dirty = false;
    },
    project(object) {
      rect = container.getBoundingClientRect();
      const v = object.getWorldPosition(new THREE.Vector3()).project(camera);
      return {
        x: (v.x * 0.5 + 0.5) * rect.width + rect.left,
        y: (-v.y * 0.5 + 0.5) * rect.height + rect.top,
        z: v.z,
      };
    },
    dispose() {
      disposed = true;
      observer.disconnect();
      const geometries = new Set(),
        materials = new Set();
      scene.traverse((o) => {
        if (o.geometry) geometries.add(o.geometry);
        if (o.material)
          (Array.isArray(o.material) ? o.material : [o.material]).forEach((m) =>
            materials.add(m),
          );
      });
      geometries.forEach((g) => g.dispose());
      materials.forEach((m) => m.dispose());
      texture.dispose();
      bloom.dispose();
      output.dispose();
      composer.dispose();
      renderer.dispose();
      renderer.forceContextLoss();
      renderer.domElement.remove();
    },
  };
}
export function makeNeuron(position, color, texture, size = 0.065) {
  const neuron = new THREE.Group();
  neuron.position.copy(position);
  const material = new THREE.SpriteMaterial({
    map: texture,
    color,
    transparent: true,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  });
  const core = new THREE.Sprite(material);
  core.scale.setScalar(size * 3);
  neuron.add(core);
  const random = seeded(
      Math.round((position.x + 5) * 1000 + (position.y + 3) * 100),
    ),
    branches = [];
  for (let i = 0; i < 7; i++) {
    const a = (i / 7) * Math.PI * 2,
      end = new THREE.Vector3(
        Math.cos(a),
        Math.sin(a),
        random() - 0.5,
      ).multiplyScalar(0.15 + random() * 0.13);
    const mid = end
      .clone()
      .multiplyScalar(0.5)
      .add(
        new THREE.Vector3((random() - 0.5) * 0.06, (random() - 0.5) * 0.06, 0),
      );
    const points = new THREE.QuadraticBezierCurve3(
      new THREE.Vector3(),
      mid,
      end,
    ).getPoints(7);
    for (let j = 1; j < points.length; j++)
      branches.push(...points[j - 1].toArray(), ...points[j].toArray());
    const fork = end.clone().multiplyScalar(0.6),
      twig = end
        .clone()
        .add(
          new THREE.Vector3(
            (random() - 0.5) * 0.14,
            (random() - 0.5) * 0.14,
            (random() - 0.5) * 0.1,
          ),
        );
    branches.push(...fork.toArray(), ...twig.toArray());
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute(
    "position",
    new THREE.Float32BufferAttribute(branches, 3),
  );
  const dendrites = new THREE.LineSegments(
    geometry,
    new THREE.LineBasicMaterial({
      color,
      transparent: true,
      opacity: 0.65,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    }),
  );
  neuron.add(dendrites);
  neuron.userData = { core, dendrites, material };
  return neuron;
}
export function makeConnection(a, b, color, texture, index = 0) {
  const mid = a.clone().lerp(b, 0.5);
  mid.z += 0.18 + Math.sin(index * 2.4) * 0.25;
  mid.y += Math.cos(index * 1.7) * 0.14;
  const curve = new THREE.QuadraticBezierCurve3(a, mid, b),
    geometry = new THREE.TubeGeometry(curve, 36, 0.007, 5, false);
  const line = new THREE.Mesh(
    geometry,
    new THREE.MeshBasicMaterial({
      color,
      transparent: true,
      opacity: 0.4,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    }),
  );
  const pulse = new THREE.Sprite(
    new THREE.SpriteMaterial({
      map: texture,
      color,
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    }),
  );
  pulse.scale.setScalar(0.12);
  return { line, pulse, curve };
}
