// A small cluster: a controller keeps the number of Pods at the desired count,
// and a scheduler places them on nodes. The controller keeps no memory of
// events. Each pass looks at the whole current state, which is what
// "level-triggered" means, and is why it can miss events and still be right.

export const CAPACITY = 4;
export const START_TICKS = 2;
export const NODE_GRACE_TICKS = 4;

export type PodPhase = "pending" | "starting" | "running";

export interface ClusterPod {
  id: number;
  node: string | null;
  phase: PodPhase;
  age: number;
}

export interface ClusterNode {
  name: string;
  up: boolean;
  cordoned: boolean;
  downFor: number;
}

export interface Cluster {
  tick: number;
  desired: number;
  controllerOn: boolean;
  nodes: ClusterNode[];
  pods: ClusterPod[];
  nextId: number;
  log: string[];
}

const KEPT = 30;

function note(cluster: Cluster, text: string) {
  cluster.log.unshift(`${cluster.tick} s: ${text}`);
  cluster.log.length = Math.min(cluster.log.length, KEPT);
}

export function createCluster(desired: number): Cluster {
  const cluster: Cluster = {
    tick: 0,
    desired,
    controllerOn: true,
    nodes: ["node-1", "node-2", "node-3"].map((name) => ({
      name,
      up: true,
      cordoned: false,
      downFor: 0,
    })),
    pods: [],
    nextId: 0,
    log: [],
  };
  // Start settled, with the Pods spread across the nodes.
  for (let i = 0; i < desired; i++) {
    cluster.pods.push({
      id: cluster.nextId++,
      node: cluster.nodes[i % cluster.nodes.length].name,
      phase: "running",
      age: START_TICKS,
    });
  }
  return cluster;
}

const onNode = (cluster: Cluster, name: string) =>
  cluster.pods.filter((pod) => pod.node === name);

function reconcile(cluster: Cluster) {
  const gap = cluster.desired - cluster.pods.length;
  for (let i = 0; i < gap; i++) {
    cluster.pods.push({ id: cluster.nextId++, node: null, phase: "pending", age: 0 });
  }
  if (gap > 0) note(cluster, `controller: ${cluster.pods.length - gap} of ${cluster.desired}, creating ${gap}`);
  if (gap < 0) {
    // Remove the Pods that aren't serving first.
    const order = { pending: 0, starting: 1, running: 2 };
    const victims = [...cluster.pods].sort((a, b) => order[a.phase] - order[b.phase]).slice(0, -gap);
    cluster.pods = cluster.pods.filter((pod) => !victims.includes(pod));
    note(cluster, `controller: too many, removing ${-gap}`);
  }
}

function schedule(cluster: Cluster) {
  for (const pod of cluster.pods) {
    if (pod.phase !== "pending") continue;
    const candidates = cluster.nodes
      .filter((node) => node.up && !node.cordoned)
      .map((node) => ({ node, load: onNode(cluster, node.name).length }))
      .filter(({ load }) => load < CAPACITY)
      .sort((a, b) => a.load - b.load);
    if (candidates.length === 0) continue; // it stays Pending until there's room
    pod.node = candidates[0].node.name;
    pod.phase = "starting";
    pod.age = 0;
  }
}

export function step(cluster: Cluster) {
  cluster.tick += 1;
  for (const node of cluster.nodes) {
    node.downFor = node.up ? 0 : node.downFor + 1;
    if (!node.up && node.downFor === NODE_GRACE_TICKS) {
      const lost = onNode(cluster, node.name).length;
      cluster.pods = cluster.pods.filter((pod) => pod.node !== node.name);
      if (lost > 0) note(cluster, `${node.name} presumed dead: ${lost} Pods evicted`);
    }
  }
  for (const pod of cluster.pods) {
    pod.age += 1;
    const up = cluster.nodes.find((node) => node.name === pod.node)?.up;
    if (pod.phase === "starting" && up && pod.age >= START_TICKS) pod.phase = "running";
  }
  if (cluster.controllerOn) reconcile(cluster);
  schedule(cluster);
}

export function killPod(cluster: Cluster, id: number) {
  cluster.pods = cluster.pods.filter((pod) => pod.id !== id);
  note(cluster, `you killed Pod ${id}`);
}

export function setDesired(cluster: Cluster, desired: number) {
  cluster.desired = desired;
  note(cluster, `desired count set to ${desired}`);
}

export function setController(cluster: Cluster, on: boolean) {
  cluster.controllerOn = on;
  note(cluster, on ? "controller back: it reads the state afresh" : "controller stopped");
}

export function setNodeUp(cluster: Cluster, name: string, up: boolean) {
  const node = cluster.nodes.find((candidate) => candidate.name === name)!;
  node.up = up;
  note(cluster, up ? `${name} is back` : `${name} went down`);
}

// Cordon a node so nothing new lands on it, then remove its Pods.
export function drain(cluster: Cluster, name: string) {
  const node = cluster.nodes.find((candidate) => candidate.name === name)!;
  node.cordoned = true;
  cluster.pods = cluster.pods.filter((pod) => pod.node !== name);
  note(cluster, `${name} cordoned and drained`);
}

export function uncordon(cluster: Cluster, name: string) {
  cluster.nodes.find((candidate) => candidate.name === name)!.cordoned = false;
  note(cluster, `${name} uncordoned`);
}

export function serving(cluster: Cluster): number {
  return cluster.pods.filter((pod) => {
    const up = cluster.nodes.find((node) => node.name === pod.node)?.up;
    return pod.phase === "running" && up;
  }).length;
}
