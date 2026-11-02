export interface Lab {
  url: string;
  area: string;
  title: string;
  blurb: string;
}

export const LABS: Lab[] = [
  { url: "/labs/rollout/", area: "DevOps", title: "Roll out a bad release", blurb: "Ship a broken version and see whether your health checks stop it, or your users find it first." },
  { url: "/labs/control-loop/", area: "Platform", title: "The control loop", blurb: "Kill Pods, drain nodes and stop the controller, then watch the cluster pull itself back." },
  { url: "/labs/burn-rate/", area: "SRE", title: "Burn the error budget", blurb: "Inject outages and find out which alerts wake someone up, and which ones cry wolf." },
  { url: "/labs/retry-storm/", area: "Backend infrastructure", title: "The retry storm", blurb: "One slow dependency, and clients whose retries keep it down long after the cause has gone." },
  { url: "/labs/disk/", area: "Systems", title: "Crash the disk", blurb: "Cut the power in the middle of a write, on real bytes, and see what a checksummed log saves." },
  { url: "/labs/audit-log/", area: "Security", title: "Tamper with the audit log", blurb: "Rewrite history as an attacker, with real SHA-256, and see what catches you." },
  { url: "/labs/drift/", area: "MLOps", title: "When a model drifts", blurb: "Move the live data away from the training data, and find the failure that PSI can't see." },
  { url: "/labs/anomaly/", area: "AIOps", title: "Catch the incident", blurb: "Tune three detectors against injected incidents, and trade missed outages for false alarms." },
  { url: "/labs/queue/", area: "Performance", title: "Why queues fall off a cliff", blurb: "Push a server towards full load and watch the wait explode." },
  { url: "/labs/raft/", area: "Distributed systems", title: "Electing a leader", blurb: "Crash nodes, split the network, and watch a Raft cluster recover." },
];
