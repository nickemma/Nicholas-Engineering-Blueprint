export interface Lab {
  url: string;
  area: string;
  practice: string;
  title: string;
  blurb: string;
}

export const LABS: Lab[] = [
  { url: "/labs/rollout/", practice: "/3-tracks/shared-units/kubernetes-and-delivery/gate/", area: "DevOps", title: "Roll out a bad release", blurb: "Ship a broken version and see whether your health checks stop it, or your users find it first." },
  { url: "/labs/control-loop/", practice: "/3-tracks/shared-units/kubernetes-and-delivery/gate/", area: "Platform", title: "The control loop", blurb: "Kill Pods, drain nodes and stop the controller, then watch the cluster pull itself back." },
  { url: "/labs/burn-rate/", practice: "/2-core/08-shipping-safely/gate/", area: "SRE", title: "Burn the error budget", blurb: "Inject outages and find out which alerts wake someone up, and which ones cry wolf." },
  { url: "/labs/retry-storm/", practice: "/3-tracks/shared-units/messaging-and-resilience/gate/", area: "Backend infrastructure", title: "The retry storm", blurb: "One slow dependency, and clients whose retries keep it down long after the cause has gone." },
  { url: "/labs/disk/", practice: "/2-core/04-rust-foundations/gate/", area: "Systems", title: "Crash the disk", blurb: "Cut the power in the middle of a write, on real bytes, and see what a checksummed log saves." },
  { url: "/labs/agent/", practice: "/3-tracks/ai-infrastructure/04-securing-the-ai-layer/exercises/", area: "AI security", title: "Talk an assistant into it", blurb: "Real attacks on a real model, recorded. Switch controls on and off and see which ones actually stop the harm." },
  { url: "/labs/audit-log/", practice: "/3-tracks/storage-engines/04-integrity-and-encryption/gate/", area: "Security", title: "Tamper with the audit log", blurb: "Rewrite history as an attacker, with real SHA-256, and see what catches you." },
  { url: "/labs/drift/", practice: "/3-tracks/ai-infrastructure/01-ml-for-infrastructure/gate/", area: "MLOps", title: "When a model drifts", blurb: "Move the live data away from the training data, and find the failure that PSI can't see." },
  { url: "/labs/anomaly/", practice: "/3-tracks/ai-infrastructure/deep-dives/aiops/", area: "AIOps", title: "Catch the incident", blurb: "Tune three detectors against injected incidents, and trade missed outages for false alarms." },
  { url: "/labs/queue/", practice: "/2-core/02-python-runtime-and-honest-measurement/gate/", area: "Performance", title: "Why queues fall off a cliff", blurb: "Push a server towards full load and watch the wait explode." },
  { url: "/labs/raft/", practice: "/2-core/07-distributed-systems-fundamentals/gate/", area: "Distributed systems", title: "Electing a leader", blurb: "Crash nodes, split the network, and watch a Raft cluster recover." },
];
