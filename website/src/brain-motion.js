import { captures, edgeKey } from "./graph-data.js";
const clamp = (v, a = 0, b = 1) => Math.max(a, Math.min(b, v));
const ease = (t) => {
  t = clamp(t);
  return t * t * (3 - 2 * t);
};
/** Absolute recording-time choreography: seeking and pausing never accumulate motion. */
export function brainMotion(time, anchors) {
  const elapsed = clamp(Number(time) || 0, 0, 45);
  let previous = { yaw: 0, pitch: 0 },
    result = {
      edge: null,
      progress: 0,
      pulse: false,
      yaw: 0,
      pitch: 0,
      destination: null,
    };
  for (let i = 0; i < captures.length; i++) {
    const capture = captures[i],
      start = capture.arrivalAt + 0.45;
    if (elapsed < start) break;
    const pair =
      (i === captures.length - 1
        ? capture.edges.find((pair) => pair.includes("report"))
        : null) ||
      capture.edges.find(
        ([a, b]) => a === capture.target || b === capture.target,
      ) ||
      capture.edges[0];
    if (!pair) continue;
    const destination =
      i === captures.length - 1
        ? "report"
        : pair.includes(capture.target)
          ? capture.target
          : pair[1];
    const source = pair.find((id) => id !== destination);
    const position = anchors[destination]?.position || [0, 0, 1];
    const desiredYaw = -Math.atan2(position[0], position[2]);
    // Unwrap onto the nearest turn: the whole cortex can be revealed without
    // ever spinning the long way around or accumulating frame-based drift.
    const delta = Math.atan2(
      Math.sin(desiredYaw - previous.yaw),
      Math.cos(desiredYaw - previous.yaw),
    );
    const target = {
      yaw: previous.yaw + delta,
      pitch: clamp(position[1] * 0.1, -0.12, 0.12),
    };
    const duration = Math.min(
      2.6,
      (captures[i + 1]?.arrivalAt ?? 45) - start - 0.25,
    );
    const progress = clamp((elapsed - start) / duration),
      movement = ease(progress);
    result = {
      edge: edgeKey(...pair),
      progress,
      pulse: progress < 1,
      yaw: previous.yaw + (target.yaw - previous.yaw) * movement,
      pitch: previous.pitch + (target.pitch - previous.pitch) * movement,
      destination,
      source,
    };
    previous = target;
  }
  // The final recap settles back to the opening pose before replay.
  if (elapsed > 44) {
    const settle = ease(elapsed - 44);
    const homeDelta = Math.atan2(Math.sin(-result.yaw), Math.cos(-result.yaw));
    result.yaw += homeDelta * settle;
    result.pitch *= 1 - settle;
  }
  return result;
}
