// The landing-page stage: a 45-second sample call. Each commitment is caught in
// the notch, then travels into a living brain built from the real cortex assets.
export const LOOP = 45;
const IGN = 3.7,
  FINALE = 42.4;

export const TURNS = [
  { at: 4, who: "Maya", text: "Quick check-in. Can we have the weekly report ready for Friday?", key: "weekly report ready for Friday", fact: "Weekly report is due Friday", target: "report", nodes: ["report", "friday"], edges: ["friday:report"] },
  { at: 8, who: "You", text: "Yes. I’ll finish the first draft by Wednesday.", key: "first draft by Wednesday", fact: "You: first draft by Wednesday", target: "draft", nodes: ["you", "draft"], edges: ["draft:you", "draft:report"] },
  { at: 12, who: "Maya", text: "I’ll review it Thursday, so we can share it Friday.", key: "review it Thursday", fact: "Maya: reviews it Thursday", target: "review", nodes: ["maya", "review"], edges: ["maya:review", "report:review"] },
  { at: 18, who: "You", text: "Let’s use the same report template as last week.", key: "same report template", fact: "Reuse last week’s template", target: "template", nodes: ["template"], edges: ["report:template"] },
  { at: 24, who: "Maya", text: "We’re still waiting for the final figures from Finance.", key: "waiting for the final figures", fact: "Blocked: Finance’s figures", target: "finance", nodes: ["finance"], edges: ["finance:report"] },
  { at: 29, who: "You", text: "I’ll follow up with Finance today and add the figures to the draft.", key: "follow up with Finance today", fact: "You: chase Finance today", target: "followup", nodes: ["followup"], edges: ["followup:you", "finance:followup"] },
  { at: 35, who: "Maya", text: "Thanks. Finance has confirmed they’ll send them this afternoon.", key: "send them this afternoon", fact: "Finance: figures this afternoon", target: "finance", nodes: [], edges: ["draft:finance", "finance:you"] },
  { at: 39, who: "You", text: "Great. Draft Wednesday, your review Thursday, and we share Friday.", key: "we share Friday", fact: "Plan confirmed for Friday", target: "friday", nodes: [], edges: [] },
];
const MEMORY = ["report", "friday", "you", "draft", "maya", "review", "template", "finance", "followup"];
const MEMORY_AT = Object.fromEntries(
  MEMORY.map((id) => {
    const turn = TURNS.find((t) => t.target === id || t.nodes.includes(id));
    return [id, turn ? turn.at + IGN : FINALE];
  }),
);

const clamp = (x) => (x < 0 ? 0 : x > 1 ? 1 : x);
const ease = (x) => ((x = clamp(x)), x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2);
const easeOut = (x) => 1 - (1 - clamp(x)) ** 3;
const bez = (a, c, b, p) => {
  const q = 1 - p;
  return { x: q * q * a.x + 2 * q * p * c.x + p * p * b.x, y: q * q * a.y + 2 * q * p * c.y + p * p * b.y };
};
export function turnAt(t) {
  let turn = -1,
    landed = -1;
  TURNS.forEach((tr, i) => {
    if (t >= tr.at) turn = i;
    if (t >= tr.at + 2) landed = i;
  });
  return { turn, landed };
}

// Column-major 4×4 helpers.
const mul = (a, b) => {
  const o = new Float32Array(16);
  for (let c = 0; c < 4; c++)
    for (let r = 0; r < 4; r++) {
      let s = 0;
      for (let k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
      o[c * 4 + r] = s;
    }
  return o;
};
const perspective = (fy, asp, n, f) => {
  const t = 1 / Math.tan(fy / 2),
    o = new Float32Array(16);
  o[0] = t / asp;
  o[5] = t;
  o[10] = (f + n) / (n - f);
  o[11] = -1;
  o[14] = (2 * f * n) / (n - f);
  return o;
};
const rotX = (a) => new Float32Array([1, 0, 0, 0, 0, Math.cos(a), Math.sin(a), 0, 0, -Math.sin(a), Math.cos(a), 0, 0, 0, 0, 1]);
const rotY = (a) => new Float32Array([Math.cos(a), 0, -Math.sin(a), 0, 0, 1, 0, 0, Math.sin(a), 0, Math.cos(a), 0, 0, 0, 0, 1]);
const translate = (x, y, z) => new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]);
const apply = (m, p) => [
  m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
  m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
  m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
  m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15],
];
const mat3 = (m) => new Float32Array([m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]]);

// Activity waves: each recent spike sends a ring of light across the folds.
const WAVE = `uniform vec4 uSpk[16];uniform float uAmp[16];uniform float uTime;
float wave(vec3 p){float a=0.0;for(int i=0;i<16;i++){float age=uTime-uSpk[i].w;if(age>0.0&&age<3.4){vec3 q=p-uSpk[i].xyz;float dd=length(q);float d=dd-age*1.15;a+=uAmp[i]*exp(-d*d*48.0)*exp(-age*1.25);a+=uAmp[i]*exp(-dd*dd*26.0)*exp(-age*2.6)*1.4;}}return a;}`;
const SHADERS = {
  mesh: [
    `attribute vec3 aPos;attribute vec3 aNor;uniform mat4 uMVP;uniform mat3 uRot;varying vec3 vN;varying vec3 vP;
void main(){vN=uRot*aNor;vP=aPos;gl_Position=uMVP*vec4(aPos,1.0);}`,
    `precision highp float;varying vec3 vN;varying vec3 vP;uniform vec3 uAcc;${WAVE}
void main(){vec3 n=normalize(vN);float f=pow(1.0-max(n.z,0.0),2.4);float l=max(dot(n,normalize(vec3(-0.35,0.7,0.6))),0.0);
vec3 c=vec3(0.012,0.032,0.036)+vec3(0.02,0.07,0.075)*l+uAcc*f*0.22+uAcc*wave(vP)*0.18;gl_FragColor=vec4(c,1.0);}`,
  ],
  fold: [
    `attribute vec3 aPos;uniform mat4 uMVP;uniform float uBase;varying float vA;varying float vW;${WAVE}
void main(){gl_Position=uMVP*vec4(aPos,1.0);float w=wave(aPos);float tw=0.62+0.38*sin(uTime*0.9+dot(aPos,vec3(9.1,6.3,4.7)));vA=uBase*tw+w*0.9;vW=w;}`,
    `precision mediump float;varying float vA;varying float vW;uniform vec3 uCol;uniform vec3 uAcc;
void main(){vec3 c=mix(uCol,mix(uAcc,vec3(1.0),clamp(vW-0.5,0.0,1.0)),clamp(vW*1.4,0.0,1.0));gl_FragColor=vec4(c*vA,1.0);}`,
  ],
  points: [
    `attribute vec3 aPos;attribute vec4 aCol;attribute float aSize;uniform mat4 uMVP;uniform float uPx;uniform float uWaveOn;varying vec4 vC;${WAVE}
void main(){vec4 c=uMVP*vec4(aPos,1.0);gl_Position=c;float w=uWaveOn>0.5?wave(aPos):0.0;
float tw=uWaveOn>0.5?(0.45+0.55*pow(0.5+0.5*sin(uTime*1.7+dot(aPos,vec3(31.1,17.7,9.3))),3.0)):1.0;
vC=vec4(aCol.rgb+vec3(w*0.7),aCol.a*tw+w*1.1);gl_PointSize=max(1.0,aSize*uPx/c.w*(1.0+w*1.2));}`,
    `precision mediump float;varying vec4 vC;
void main(){vec2 d=gl_PointCoord-0.5;float r=length(d)*2.0;if(r>1.0)discard;float a=pow(1.0-r,2.2)+exp(-r*r*24.0)*0.9;gl_FragColor=vec4(vC.rgb*vC.a*a,1.0);}`,
  ],
  axon: [
    `attribute vec3 aPos;attribute float aEdge;attribute float aT;uniform mat4 uMVP;uniform float uEdgeA[64];uniform float uPulse[64];varying float vA;
void main(){gl_Position=uMVP*vec4(aPos,1.0);int i=int(aEdge+0.5);float pt=uPulse[i];float g=pt>=0.0?exp(-(aT-pt)*(aT-pt)*700.0)*1.8:0.0;vA=uEdgeA[i]+g;}`,
    `precision mediump float;varying float vA;uniform vec3 uAcc;
void main(){vec3 c=mix(uAcc,vec3(1.0),clamp(vA-0.9,0.0,1.0));gl_FragColor=vec4(c*vA,1.0);}`,
  ],
};
function program(gl, [vs, fs]) {
  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw Error(gl.getShaderInfoLog(s));
    return s;
  };
  const p = gl.createProgram();
  gl.attachShader(p, compile(gl.VERTEX_SHADER, vs));
  gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw Error(gl.getProgramInfoLog(p));
  const u = {},
    a = {};
  for (let i = 0; i < gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS); i++) {
    const info = gl.getActiveUniform(p, i);
    u[info.name.replace("[0]", "")] = gl.getUniformLocation(p, info.name);
  }
  for (let i = 0; i < gl.getProgramParameter(p, gl.ACTIVE_ATTRIBUTES); i++) {
    const info = gl.getActiveAttrib(p, i);
    a[info.name] = gl.getAttribLocation(p, info.name);
  }
  return { p, u, a };
}

const load = async (url, type = "json") => {
  const r = await fetch(url);
  if (!r.ok) throw Error(`Could not load ${url}`);
  return type === "json" ? r.json() : r.arrayBuffer();
};

// A neural network on the cortex: knowledge anchors are neurons, baked surface
// routes are axons. Neurons charge, fire, and pass action potentials on.
export function createLivingBrain(canvas, onReady) {
  const gl = canvas.getContext("webgl", { alpha: true, premultipliedAlpha: true, antialias: true, powerPreference: "high-performance" });
  if (!gl || !gl.getExtension("OES_element_index_uint")) return null;
  let progs;
  try {
    progs = Object.fromEntries(Object.entries(SHADERS).map(([k, v]) => [k, program(gl, v)]));
  } catch {
    return null;
  }
  const spikes = Array.from({ length: 16 }, () => ({ p: [0, 0, 0], t: -99, a: 0 })),
    spk = new Float32Array(64),
    amp = new Float32Array(16),
    edgeA = new Float32Array(64),
    edgePulse = new Float32Array(64).fill(-1),
    neurons = {},
    ids = [],
    edges = [],
    edgeByKey = {},
    pulses = [],
    buf = {},
    dynBuf = gl.createBuffer();
  let spkI = 0,
    ready = false,
    lost = false,
    mvp = null,
    rot = null,
    counts = {};
  canvas.addEventListener("webglcontextlost", (e) => {
    e.preventDefault();
    lost = true;
  });

  Promise.all([
    load("/models/cortex.json"),
    load("/models/cortex.bin", "buffer"),
    load("/models/neural-paths.json"),
    load("/models/neural-folds.bin", "buffer"),
  ])
    .then(([meta, cortex, network, folds]) => {
      const V = meta.vertices;
      const array = (data, target = gl.ARRAY_BUFFER) => {
        const b = gl.createBuffer();
        gl.bindBuffer(target, b);
        gl.bufferData(target, data, gl.STATIC_DRAW);
        return b;
      };
      buf.pos = array(new Float32Array(cortex, 0, V * 3));
      buf.nor = array(new Float32Array(cortex, V * 12, V * 3));
      buf.idx = array(new Uint32Array(cortex, V * 24, meta.indices), gl.ELEMENT_ARRAY_BUFFER);
      const foldVerts = new Float32Array(folds);
      buf.fold = array(foldVerts);
      counts = { idx: meta.indices, contour: network.contourVertices, slice: network.sliceVertices };
      // Fine cells sit on the folds, lifted a touch.
      const cells = [];
      for (let c = 0; c < network.contourVertices; c += 11) {
        const j = c * 3;
        cells.push(foldVerts[j] * 1.008, foldVerts[j + 1] * 1.008, foldVerts[j + 2] * 1.008, 0.55 + Math.random() * 0.2, 0.92, 0.86, 0.5, 0.018 + Math.random() * 0.016);
      }
      buf.cells = array(new Float32Array(cells));
      counts.cells = cells.length / 8;
      for (const [id, a] of Object.entries(network.anchors)) {
        const [p, n] = [a.position, a.normal];
        neurons[id] = { id, p: p.map((v, i) => v + n[i] * 0.03), n, v: 0, last: -99, flash: -99, flashAmp: 0.5, lit: -1, adj: [] };
        ids.push(id);
      }
      const ax = [];
      Object.entries(network.paths)
        .slice(0, 64)
        .forEach(([key, raw], i) => {
          const pts = raw.map((q) => q.map((v) => v * 1.006)),
            cum = [0];
          for (let m = 1; m < pts.length; m++) cum.push(cum[m - 1] + Math.hypot(pts[m][0] - pts[m - 1][0], pts[m][1] - pts[m - 1][1], pts[m][2] - pts[m - 1][2]));
          const [a, b] = key.split(":"),
            len = cum.at(-1) || 1,
            e = { key, a, b, pts, cum, len, i, strong: 0 };
          edges.push(e);
          edgeByKey[key] = e;
          neurons[a]?.adj.push(e);
          neurons[b]?.adj.push(e);
          for (let m = 1; m < pts.length; m++) ax.push(...pts[m - 1], i, cum[m - 1] / len, ...pts[m], i, cum[m] / len);
        });
      buf.axon = array(new Float32Array(ax));
      counts.axon = ax.length / 5;
      ready = true;
      onReady?.();
    })
    .catch(() => {});

  function along(e, p) {
    const target = p * e.len;
    let m = 1;
    while (m < e.cum.length - 1 && e.cum[m] < target) m++;
    const f = clamp((target - e.cum[m - 1]) / (e.cum[m] - e.cum[m - 1] || 1)),
      A = e.pts[m - 1],
      C = e.pts[m];
    return [A[0] + (C[0] - A[0]) * f, A[1] + (C[1] - A[1]) * f, A[2] + (C[2] - A[2]) * f];
  }
  function fire(id, strength, gen, t) {
    const n = neurons[id];
    if (!n || (gen > 0 && t - n.last < 0.8)) return;
    Object.assign(n, { last: t, flash: t, v: 0, flashAmp: strength });
    Object.assign(spikes[spkI], { p: n.p, t, a: Math.min(1.2, strength) });
    spkI = (spkI + 1) % 16;
    if (gen >= 3) return;
    for (const e of n.adj) {
      if (gen > 0 && Math.random() > 0.6) continue;
      pulses.push({ e, fromA: e.a === id, t0: t + Math.random() * 0.08, amp: strength * 0.82, gen: gen + 1, speed: 1.5 + Math.random() * 0.6 });
    }
  }

  function render(t, dt, view) {
    if (!ready || lost) return;
    // Slow devices drop to 1× pixels and skip the faint slice lines.
    const dpr = view.low ? 1 : Math.min(devicePixelRatio || 1, innerWidth < 760 ? 1.5 : 2),
      cw = canvas.clientWidth,
      ch = canvas.clientHeight;
    if (!cw || !ch) return;
    const W = Math.round(cw * dpr),
      H = Math.round(ch * dpr);
    if (canvas.width !== W || canvas.height !== H) {
      canvas.width = W;
      canvas.height = H;
    }
    // Background activity: neurons idle and fire on their own.
    if (dt > 0 && Math.random() < dt * 1.6) fire(ids[Math.floor(Math.random() * ids.length)], 0.32 + Math.random() * 0.25, 2, t);
    for (let q = pulses.length - 1; q >= 0; q--) {
      const P = pulses[q],
        pr = ((t - P.t0) * P.speed) / P.e.len;
      if (pr >= 1) {
        const to = neurons[P.fromA ? P.e.b : P.e.a];
        if (to) {
          to.v += P.amp;
          if (to.v > 0.42) fire(to.id, P.amp, P.gen, t);
        }
        pulses.splice(q, 1);
      } else P.pr = pr;
    }
    for (const id of ids) neurons[id].v *= Math.exp(-dt * 1.4);

    const { acc, fade: g } = view;
    rot = mul(rotX(view.pitch), rotY(view.yaw));
    mvp = mul(perspective(0.52, cw / ch, 0.1, 40), mul(translate(0, -0.05, -view.dist), rot));
    spikes.forEach((s, i) => {
      spk.set([...s.p, s.t], i * 4);
      amp[i] = s.a;
    });

    gl.viewport(0, 0, W, H);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.LEQUAL);
    const use = (pr) => {
      gl.useProgram(pr.p);
      if (pr.u.uMVP) gl.uniformMatrix4fv(pr.u.uMVP, false, mvp);
      if (pr.u.uRot) gl.uniformMatrix3fv(pr.u.uRot, false, mat3(rot));
      if (pr.u.uTime) gl.uniform1f(pr.u.uTime, t);
      if (pr.u.uSpk) gl.uniform4fv(pr.u.uSpk, spk);
      if (pr.u.uAmp) gl.uniform1fv(pr.u.uAmp, amp);
      if (pr.u.uAcc) gl.uniform3fv(pr.u.uAcc, acc);
      if (pr.u.uPx) gl.uniform1f(pr.u.uPx, H / (2 * Math.tan(0.26)));
    };
    const attr = (pr, name, b, size, stride = 0, off = 0) => {
      const loc = pr.a[name];
      if (loc === undefined || loc < 0) return;
      gl.bindBuffer(gl.ARRAY_BUFFER, b);
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, size, gl.FLOAT, false, stride, off);
    };
    const done = (pr) => Object.values(pr.a).forEach((loc) => gl.disableVertexAttribArray(loc));

    // 1. The cortex: dark and rim-lit, writing depth so the far side hides.
    gl.disable(gl.BLEND);
    gl.depthMask(true);
    gl.enable(gl.POLYGON_OFFSET_FILL);
    gl.polygonOffset(2, 2);
    use(progs.mesh);
    attr(progs.mesh, "aPos", buf.pos, 3);
    attr(progs.mesh, "aNor", buf.nor, 3);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, buf.idx);
    gl.drawElements(gl.TRIANGLES, counts.idx, gl.UNSIGNED_INT, 0);
    done(progs.mesh);
    gl.disable(gl.POLYGON_OFFSET_FILL);

    // 2. The folds, lit by travelling waves of activity.
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE);
    gl.depthMask(false);
    const F = progs.fold;
    use(F);
    attr(F, "aPos", buf.fold, 3);
    gl.uniform3fv(F.u.uCol, [0.55, 0.79, 0.77]);
    gl.uniform1f(F.u.uBase, 0.34);
    gl.drawArrays(gl.LINES, 0, counts.contour);
    if (!view.low) {
      gl.uniform3fv(F.u.uCol, [0.32, 0.6, 0.62]);
      gl.uniform1f(F.u.uBase, 0.12);
      gl.drawArrays(gl.LINES, counts.contour, counts.slice);
    }
    done(F);

    // 3. Axons; strengthened links stay bright, action potentials glow along them.
    edgePulse.fill(-1);
    for (const e of edges) edgeA[e.i] = 0.07 + 0.62 * (e.strong && t >= e.strong ? ease((t - e.strong) / 1.2) * g : 0);
    for (const P of pulses) if (P.pr !== undefined) edgePulse[P.e.i] = P.fromA ? P.pr : 1 - P.pr;
    const A = progs.axon;
    use(A);
    gl.uniform1fv(A.u.uEdgeA, edgeA);
    gl.uniform1fv(A.u.uPulse, edgePulse);
    attr(A, "aPos", buf.axon, 3, 20, 0);
    attr(A, "aEdge", buf.axon, 1, 20, 12);
    attr(A, "aT", buf.axon, 1, 20, 16);
    gl.drawArrays(gl.LINES, 0, counts.axon);
    done(A);

    // 4. Fine cells shimmering as waves pass.
    const Pt = progs.points;
    use(Pt);
    gl.uniform1f(Pt.u.uWaveOn, 1);
    attr(Pt, "aPos", buf.cells, 3, 32, 0);
    attr(Pt, "aCol", buf.cells, 4, 32, 12);
    attr(Pt, "aSize", buf.cells, 1, 32, 28);
    gl.drawArrays(gl.POINTS, 0, counts.cells);
    done(Pt);

    // 5. Somas, action potentials and their trails.
    const dyn = [];
    ids.forEach((id, k) => {
      const n = neurons[id],
        lit = n.lit >= 0 && t >= n.lit ? ease((t - n.lit) / 0.6) * g : 0,
        fl = Math.exp(-Math.max(0, t - n.flash) * 3.2) * n.flashAmp,
        breathe = 0.5 + 0.5 * Math.sin(t * 1.3 + k * 2.1),
        mix = (c) => c + (1 - c) * fl * 0.8;
      dyn.push(...n.p, mix(acc[0]), mix(acc[1]), mix(acc[2]), 0.32 + 0.12 * breathe + lit * 0.7 + fl * 1.2, 0.05 + lit * 0.05 + fl * 0.12);
      if (lit > 0) dyn.push(...n.p, ...acc, 0.25 * lit * (0.7 + 0.3 * breathe), 0.26 + 0.04 * breathe);
    });
    for (const P of pulses) {
      if (P.pr === undefined) continue;
      for (let tr = 0; tr < 5; tr++) {
        const pr = P.pr - tr * 0.028;
        if (pr < 0) break;
        const hot = tr === 0;
        dyn.push(...along(P.e, P.fromA ? pr : 1 - pr), hot ? 0.9 : acc[0], hot ? 1 : acc[1], hot ? 0.96 : acc[2], (0.95 - tr * 0.17) * Math.min(1, P.amp * 1.4), hot ? 0.07 : 0.045 - tr * 0.006);
      }
    }
    gl.bindBuffer(gl.ARRAY_BUFFER, dynBuf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(dyn), gl.DYNAMIC_DRAW);
    use(Pt);
    gl.uniform1f(Pt.u.uWaveOn, 0);
    attr(Pt, "aPos", dynBuf, 3, 32, 0);
    attr(Pt, "aCol", dynBuf, 4, 32, 12);
    attr(Pt, "aSize", dynBuf, 1, 32, 28);
    gl.drawArrays(gl.POINTS, 0, dyn.length / 8);
    done(Pt);
    gl.depthMask(true);
  }

  return {
    get ready() {
      return ready && !lost;
    },
    fire,
    remember(id, t) {
      if (neurons[id] && neurons[id].lit < 0) neurons[id].lit = t;
    },
    strengthen(key, t) {
      const e = edgeByKey[key];
      if (e && !e.strong) e.strong = t;
    },
    reset() {
      for (const id of ids) Object.assign(neurons[id], { lit: -1, v: 0 });
      for (const e of edges) e.strong = 0;
      pulses.length = 0;
    },
    render,
    // Canvas-relative position of a neuron and how squarely it faces the viewer.
    screen(id) {
      const n = neurons[id];
      if (!n || !mvp) return null;
      const c = apply(mvp, n.p);
      if (c[3] <= 0) return null;
      return {
        x: (c[0] / c[3] / 2 + 0.5) * canvas.clientWidth,
        y: (-c[1] / c[3] / 2 + 0.5) * canvas.clientHeight,
        facing: rot[2] * n.n[0] + rot[6] * n.n[1] + rot[10] * n.n[2],
      };
    },
    facingYaw(id) {
      const n = neurons[id];
      return n ? Math.atan2(-n.n[0], n.n[2]) : null;
    },
    dispose() {
      gl.getExtension("WEBGL_lose_context")?.loseContext();
    },
  };
}

export function createStage(root, { onTick, onInteract } = {}) {
  const q = (s) => root.querySelector(s),
    $a = (name) => q(`[data-a="${name}"]`);
  const el = {
    layer: $a("layer"), chip: $a("chip"), chipKey: $a("chipKey"), chipFact: $a("chipFact"),
    caption: $a("caption"), capWho: $a("capWho"), capPre: $a("capPre"), capKey: $a("capKey"), capPost: $a("capPost"),
    notchGlow: $a("notchGlow"), notchIn: $a("notchIn"), notchOut: $a("notchOut"), standing: $a("standing"), kept: $a("kept"), clock: $a("clock"),
    canvas: $a("brainCanvas"), img: $a("brainImg"), wrap: $a("brainWrap"), progress: $a("progress"), saved: $a("saved"),
    rings: { Maya: $a("ring-Maya"), You: $a("ring-You") },
    dots: [0, 1, 2, 3].map((i) => $a(`pk${i}`)),
    steps: [...root.querySelectorAll("[data-step]")],
    labels: Object.fromEntries(MEMORY.map((id) => [id, q(`[data-blabel="${id}"]`)])),
  };
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");
  const accent = [0.431, 0.906, 0.627];
  const brain = createLivingBrain(el.canvas, () => {
    el.canvas.style.opacity = 1;
    el.img.style.opacity = 0;
  });
  let elapsed = 0,
    last = 0,
    prevT = 0,
    playing = true,
    visible = false,
    raf = 0,
    shown = { turn: -2, landed: -2 },
    yaw = 0.6,
    yawVel = 0.15,
    pitch = 0.36,
    drag = null,
    dragUntil = 0,
    lastSec = -1,
    frameCost = 1 / 60,
    lowQuality = false;

  function showTurn(ti, li) {
    if (ti !== shown.turn) {
      const tr = TURNS[ti];
      if (tr) {
        const i = tr.text.indexOf(tr.key);
        el.capWho.textContent = `${tr.who}:`;
        el.capPre.textContent = tr.text.slice(0, i);
        el.capKey.textContent = tr.key;
        el.capPost.textContent = tr.text.slice(i + tr.key.length);
        el.chipKey.textContent = tr.key;
        el.chipFact.textContent = tr.fact;
      }
    }
    if (li !== shown.landed) {
      el.standing.textContent = li >= 0 ? TURNS[li].fact : "Listening for what matters…";
      el.kept.replaceChildren(
        ...TURNS.slice(Math.max(0, li - 3), Math.max(0, li))
          .reverse()
          .map((tr) => Object.assign(document.createElement("li"), { textContent: tr.fact })),
      );
    }
    shown = { turn: ti, landed: li };
  }

  function frame(now) {
    raf = requestAnimationFrame(frame);
    // Real time drives the call; only long gaps (a background tab) are clipped.
    const dt = last ? Math.min(0.25, (now - last) / 1000) : 0;
    last = now;
    if (!visible || document.hidden) return;
    frameCost = frameCost * 0.95 + dt * 0.05;
    if (!lowQuality && elapsed > 3 && frameCost > 0.04) lowQuality = true;
    const running = playing;
    if (running) elapsed += dt;
    const t = elapsed % LOOP;
    if (t < prevT) brain?.reset();
    const { turn: ti, landed: li } = turnAt(t);
    showTurn(ti, li);

    if (brain?.ready && running) {
      for (const tr of TURNS) {
        const hit = tr.at + IGN;
        if (prevT < hit && t >= hit) {
          brain.fire(tr.target, 1.25, 0, t);
          for (const n of [...tr.nodes, tr.target]) brain.remember(n, t);
          for (const k of tr.edges) brain.strengthen(k, t);
        }
      }
      if (prevT < FINALE && t >= FINALE) for (const n of MEMORY) brain.fire(n, 1, 1, t);
    }
    prevT = t;

    const g = 1 - ease((t - 44.2) / 0.7),
      lb = el.layer.getBoundingClientRect(),
      center = (node) => {
        const b = node.getBoundingClientRect();
        return { x: b.left + b.width / 2 - lb.left, y: b.top + b.height / 2 - lb.top };
      },
      tr = TURNS[ti],
      d = tr ? t - tr.at : -1;

    // Caption, with the key phrase lighting up.
    if (tr) {
      const k = ease(d / 0.45);
      el.caption.style.opacity = k * g;
      el.caption.style.transform = `translate3d(0,${(1 - k) * 10}px,0)`;
      const h = ease((d - 0.45) / 0.4) * (1 - 0.65 * ease((d - 1.2) / 0.5));
      el.capKey.style.backgroundColor = `rgba(110,231,160,${0.3 * h})`;
    } else el.caption.style.opacity = 0;
    for (const [who, ring] of Object.entries(el.rings))
      ring.style.opacity = tr && tr.who === who ? ease(d / 0.25) * (1 - ease((d - 3.1) / 0.5)) : 0;

    // Caption phrase -> notch.
    const f = d - 1;
    if (tr && f >= 0 && f <= 1.15) {
      const p = ease(f),
        a = center(el.capKey),
        b = center(el.notchIn),
        pos = bez(a, { x: (a.x + b.x) / 2 + (b.x - a.x) * 0.1, y: Math.min(a.y, b.y) - Math.abs(a.x - b.x) * 0.15 - 40 }, b, p),
        sc = 1 + 0.08 * Math.sin(p * Math.PI) - 0.25 * ease((f - 0.85) / 0.3);
      el.chip.style.transform = `translate3d(${pos.x - el.chip.offsetWidth / 2}px,${pos.y - el.chip.offsetHeight / 2}px,0) scale(${sc})`;
      el.chip.style.opacity = ease(f / 0.15) * (1 - ease((f - 0.95) / 0.2));
      const sw = ease((f - 0.25) / 0.35);
      el.chipKey.style.opacity = 1 - sw;
      el.chipFact.style.opacity = sw;
    } else el.chip.style.opacity = 0;

    const la = d - 2;
    el.notchGlow.style.opacity = tr && la >= 0 && la < 1.4 ? (1 - easeOut(la / 1.4)) * 0.9 : 0;
    if (li >= 0) {
      const kk = ease((t - TURNS[li].at - 2) / 0.5);
      el.standing.style.opacity = kk * g;
      el.standing.style.transform = `translate3d(0,${(1 - kk) * 8}px,0)`;
    } else {
      el.standing.style.opacity = 0.7;
      el.standing.style.transform = "none";
    }

    // Camera: drifts, turns to meet each incoming memory, spins at the finale.
    if (!drag) {
      let goal = null;
      if (brain?.ready && tr && d > 0.3 && d < 5.2 && elapsed > dragUntil && t < FINALE) {
        let fy = brain.facingYaw(tr.target);
        if (fy !== null) {
          fy += 0.3;
          while (fy - yaw > Math.PI) fy -= 2 * Math.PI;
          while (fy - yaw < -Math.PI) fy += 2 * Math.PI;
          goal = fy;
        }
      }
      if (reduced.matches) {
        yawVel = 0;
        if (goal !== null) yaw += (goal - yaw) * Math.min(1, dt * 3);
      } else if (goal !== null) {
        const k = 7.5;
        yawVel += ((goal - yaw) * k - yawVel * 2 * Math.sqrt(k) * 0.95) * dt;
        yaw += yawVel * dt;
      } else {
        const cruise = running ? (t > FINALE && t < 44.4 ? 1.1 : 0.16) : 0.05;
        yawVel += (cruise - yawVel) * Math.min(1, dt * 1.6);
        yaw += yawVel * dt;
      }
      if (elapsed > dragUntil) pitch += (0.36 + Math.sin(t * 0.21) * 0.08 - pitch) * Math.min(1, dt * 0.8);
    }
    if (brain?.ready) {
      brain.render(t, running ? dt : 0, { yaw, pitch, dist: 7.3, acc: accent, fade: g, low: lowQuality });
      for (const id of MEMORY) {
        const label = el.labels[id],
          sp = brain.screen(id);
        if (!label) continue;
        if (!sp) {
          label.style.opacity = 0;
          continue;
        }
        const on = t >= MEMORY_AT[id] ? ease((t - MEMORY_AT[id]) / 0.6) * g : 0;
        label.style.opacity = on * clamp((sp.facing + 0.05) / 0.35);
        label.style.transform = `translate3d(${sp.x}px,${sp.y - 14}px,0) translate(-50%,-100%)`;
      }
    }

    // Notch -> the target neuron, wherever the brain has turned it.
    const pf = d - 2.5;
    let target = null;
    if (tr && pf >= 0 && pf <= 1.4) {
      const sp = brain?.ready ? brain.screen(tr.target) : null,
        cr = el.canvas.getBoundingClientRect();
      target = sp ? { x: cr.left + sp.x - lb.left, y: cr.top + sp.y - lb.top } : { x: cr.left + cr.width / 2 - lb.left, y: cr.top + cr.height / 2 - lb.top };
    }
    el.dots.forEach((dot, j) => {
      const pp = ease(pf / 1.2) - j * 0.045;
      if (!target || (reduced.matches && j) || pp < 0) {
        dot.style.opacity = 0;
        return;
      }
      const A0 = center(el.notchOut),
        P0 = bez(A0, { x: A0.x + (target.x - A0.x) * 0.9, y: A0.y + (target.y - A0.y) * 0.05 }, target, Math.min(1, pp)),
        s = (1 - j * 0.22) * (1 + 0.6 * ease((pf - 1.05) / 0.2));
      dot.style.transform = `translate3d(${P0.x - 6}px,${P0.y - 6}px,0) scale(${s})`;
      dot.style.opacity = (1 - j * 0.24) * ease(pf / 0.12) * (1 - ease((pf - 1.15) / 0.2));
    });

    el.saved.style.opacity = ease((t - 42.8) / 0.5) * g;
    el.progress.style.transform = `scaleX(${t / LOOP})`;
    let phase = tr ? (d < 1 ? 1 : d < 2.5 ? 2 : d < 4.6 ? 3 : 0) : 0;
    if (t > FINALE) phase = 3;
    el.steps.forEach((s, i) => s.classList.toggle("active", phase === i + 1));
    const sec = Math.floor(t);
    if (sec !== lastSec) {
      lastSec = sec;
      el.clock.textContent = `0:${String(sec).padStart(2, "0")}`;
    }
    onTick?.(t, running);
  }

  el.canvas.addEventListener("pointerdown", (e) => {
    drag = { x: e.clientX, y: e.clientY, yaw, pitch };
    el.canvas.setPointerCapture?.(e.pointerId);
    onInteract?.();
  });
  el.canvas.addEventListener("pointermove", (e) => {
    if (!drag) return;
    const next = drag.yaw + (e.clientX - drag.x) * 0.008;
    yawVel = (next - yaw) * 60;
    yaw = next;
    pitch = Math.max(-0.4, Math.min(1.1, drag.pitch + (e.clientY - drag.y) * 0.005));
  });
  const release = () => {
    if (!drag) return;
    drag = null;
    dragUntil = elapsed + 3;
  };
  el.canvas.addEventListener("pointerup", release);
  el.canvas.addEventListener("pointercancel", release);
  new IntersectionObserver(([entry]) => (visible = entry.isIntersecting), { rootMargin: "120px" }).observe(root);
  raf = requestAnimationFrame(frame);

  return {
    get time() {
      return elapsed % LOOP;
    },
    get playing() {
      return playing;
    },
    play() {
      playing = true;
    },
    pause() {
      playing = false;
    },
    seek(at) {
      elapsed = Math.max(0, Math.min(LOOP - 0.01, at));
      prevT = elapsed;
      brain?.reset();
      // Rebuild the memories formed before this moment so the brain stays truthful.
      if (brain?.ready)
        for (const tr of TURNS)
          if (tr.at + IGN <= elapsed) {
            for (const n of [...tr.nodes, tr.target]) brain.remember(n, 0);
            for (const k of tr.edges) brain.strengthen(k, 0.01);
          }
    },
    dispose() {
      cancelAnimationFrame(raf);
      brain?.dispose();
    },
  };
}
