// Raft's leader election, and nothing else: there's no log here, so a vote
// never depends on who is more up to date. Times are in milliseconds.
import { between, rngOf, type Rng } from "./rng.ts";

export const CLUSTER = 5;
export const MAJORITY = Math.floor(CLUSTER / 2) + 1;
export const HEARTBEAT = 50;
export const TIMEOUT_LOW = 150;
export const TIMEOUT_HIGH = 300;
const LATENCY_LOW = 10;
const LATENCY_HIGH = 20;
const FIXED_TIMEOUT = 200;
const FIXED_LATENCY = 15;
const KEPT_EVENTS = 40;

export type Role = "follower" | "candidate" | "leader";
export type MessageType = "vote-request" | "vote-reply" | "heartbeat" | "heartbeat-reply";

export interface RaftNode {
  id: number;
  role: Role;
  term: number; // durable
  votedFor: number | null; // durable
  alive: boolean;
  deadline: number; // when the election timer fires
  startedWaiting: number;
  nextBeat: number;
  votes: Set<number>;
}

export interface Message {
  from: number;
  to: number;
  type: MessageType;
  term: number;
  granted: boolean;
  sentAt: number;
  deliverAt: number;
}

export interface LogEvent {
  at: number;
  text: string;
}

export interface Sim {
  now: number;
  rng: Rng;
  randomised: boolean;
  split: boolean;
  nodes: RaftNode[];
  messages: Message[];
  events: LogEvent[];
  leaderOfTerm: Map<number, number>;
  voteOfTerm: Map<string, number>;
  violations: string[];
}

export const nameOf = (id: number) => "ABCDE"[id];

// While the network is split, A and B can't reach C, D and E.
function sideOf(id: number): number {
  return id < 2 ? 0 : 1;
}

function log(sim: Sim, text: string) {
  sim.events.unshift({ at: sim.now, text });
  sim.events.length = Math.min(sim.events.length, KEPT_EVENTS);
}

function resetTimer(sim: Sim, node: RaftNode) {
  const span = sim.randomised ? between(sim.rng, TIMEOUT_LOW, TIMEOUT_HIGH) : FIXED_TIMEOUT;
  node.startedWaiting = sim.now;
  node.deadline = sim.now + span;
}

function send(sim: Sim, from: number, to: number, type: MessageType, term: number, granted = false) {
  const latency = sim.randomised ? between(sim.rng, LATENCY_LOW, LATENCY_HIGH) : FIXED_LATENCY;
  sim.messages.push({ from, to, type, term, granted, sentAt: sim.now, deliverAt: sim.now + latency });
}

function broadcast(sim: Sim, from: RaftNode, type: MessageType) {
  for (const node of sim.nodes) {
    if (node.id !== from.id) send(sim, from.id, node.id, type, from.term);
  }
}

export function createSim(seed: number, randomised = true): Sim {
  const sim: Sim = {
    now: 0,
    rng: rngOf(seed),
    randomised,
    split: false,
    nodes: [],
    messages: [],
    events: [],
    leaderOfTerm: new Map(),
    voteOfTerm: new Map(),
    violations: [],
  };
  for (let id = 0; id < CLUSTER; id++) {
    const node: RaftNode = {
      id,
      role: "follower",
      term: 0,
      votedFor: null,
      alive: true,
      deadline: 0,
      startedWaiting: 0,
      nextBeat: Infinity,
      votes: new Set(),
    };
    resetTimer(sim, node);
    sim.nodes.push(node);
  }
  return sim;
}

function stepDown(sim: Sim, node: RaftNode, term: number) {
  if (node.role === "leader") {
    log(sim, `${nameOf(node.id)} sees term ${term} and steps down`);
    resetTimer(sim, node); // a leader's election timer isn't running
  }
  node.term = term;
  node.role = "follower";
  node.votedFor = null;
  node.nextBeat = Infinity;
  node.votes.clear();
}

function recordVote(sim: Sim, voter: RaftNode, candidate: number) {
  const key = `${voter.id}:${voter.term}`;
  const earlier = sim.voteOfTerm.get(key);
  if (earlier !== undefined && earlier !== candidate) {
    sim.violations.push(`${nameOf(voter.id)} voted twice in term ${voter.term}`);
  }
  sim.voteOfTerm.set(key, candidate);
}

function becomeLeader(sim: Sim, node: RaftNode) {
  const earlier = sim.leaderOfTerm.get(node.term);
  if (earlier !== undefined && earlier !== node.id) {
    sim.violations.push(`two leaders in term ${node.term}`);
  }
  sim.leaderOfTerm.set(node.term, node.id);
  node.role = "leader";
  node.deadline = Infinity;
  node.nextBeat = sim.now + HEARTBEAT;
  log(sim, `${nameOf(node.id)} wins term ${node.term} with ${node.votes.size} votes`);
  broadcast(sim, node, "heartbeat");
}

function startElection(sim: Sim, node: RaftNode) {
  node.term += 1;
  node.role = "candidate";
  node.votedFor = node.id;
  recordVote(sim, node, node.id);
  node.votes = new Set([node.id]);
  resetTimer(sim, node);
  log(sim, `${nameOf(node.id)} timed out: candidate in term ${node.term}`);
  broadcast(sim, node, "vote-request");
}

function deliver(sim: Sim, message: Message) {
  const node = sim.nodes[message.to];
  if (!node.alive) return;
  if (sim.split && sideOf(message.from) !== sideOf(message.to)) return;
  if (message.term > node.term) stepDown(sim, node, message.term);

  switch (message.type) {
    case "vote-request": {
      const granted =
        message.term === node.term && (node.votedFor === null || node.votedFor === message.from);
      if (granted) {
        node.votedFor = message.from;
        recordVote(sim, node, message.from);
        resetTimer(sim, node);
      }
      send(sim, node.id, message.from, "vote-reply", node.term, granted);
      return;
    }
    case "vote-reply":
      if (node.role === "candidate" && message.term === node.term && message.granted) {
        node.votes.add(message.from);
        if (node.votes.size >= MAJORITY) becomeLeader(sim, node);
      }
      return;
    case "heartbeat":
      if (message.term === node.term) {
        node.role = "follower";
        node.votes.clear();
        resetTimer(sim, node);
      }
      send(sim, node.id, message.from, "heartbeat-reply", node.term);
      return;
    case "heartbeat-reply":
      return;
  }
}

// Run every event up to the given time, in order. The event at the same
// instant goes to messages first, then to nodes by id, so that a run replays.
export function advance(sim: Sim, until: number) {
  for (;;) {
    let nextMessage = -1;
    let at = Infinity;
    sim.messages.forEach((message, i) => {
      if (message.deliverAt < at) {
        at = message.deliverAt;
        nextMessage = i;
      }
    });
    const nextNode = sim.nodes
      .filter((node) => node.alive)
      .reduce<RaftNode | null>((best, node) => {
        const due = Math.min(node.deadline, node.nextBeat);
        const bestDue = best ? Math.min(best.deadline, best.nextBeat) : Infinity;
        return due < bestDue ? node : best;
      }, null);
    const nodeDue = nextNode ? Math.min(nextNode.deadline, nextNode.nextBeat) : Infinity;
    const nodeFirst = nodeDue < at;
    if (Math.min(at, nodeDue) > until) break;
    sim.now = Math.min(at, nodeDue);
    if (nextNode && nodeFirst) {
      if (nextNode.role === "leader") {
        nextNode.nextBeat = sim.now + HEARTBEAT;
        broadcast(sim, nextNode, "heartbeat");
      } else {
        startElection(sim, nextNode);
      }
    } else {
      const [message] = sim.messages.splice(nextMessage, 1);
      deliver(sim, message);
    }
  }
  sim.now = until;
}

export function crash(sim: Sim, id: number) {
  const node = sim.nodes[id];
  node.alive = false;
  node.role = "follower";
  node.votes.clear();
  node.nextBeat = Infinity;
  log(sim, `${nameOf(id)} crashed`);
}

// A restart keeps the term and the vote, which is why they must be durable.
export function restart(sim: Sim, id: number) {
  const node = sim.nodes[id];
  node.alive = true;
  resetTimer(sim, node);
  log(sim, `${nameOf(id)} restarted in term ${node.term}`);
}

export function setSplit(sim: Sim, split: boolean) {
  sim.split = split;
  log(sim, split ? "Network split: A B | C D E" : "Network healed");
}

// The leader of the highest term that any live node leads.
export function currentLeader(sim: Sim): RaftNode | null {
  let best: RaftNode | null = null;
  for (const node of sim.nodes) {
    if (node.alive && node.role === "leader" && (!best || node.term > best.term)) best = node;
  }
  return best;
}
