// Project status shown on the site. Update it in the same pull request as the evidence that changes it.
// A state may be "verified" only when evidence/ holds a recorded test for it.

export const MATRIX = [
  {
    os: 'macOS',
    apps: { state: 'unverified', how: 'Signed Network Extension with a small host app.' },
    tasks: { state: 'probe', how: 'Experimental session mode: the built-in sandbox plus a local proxy.' },
  },
  {
    os: 'Linux',
    apps: { state: 'unverified', how: 'Host coverage with trustworthy process attribution. Mechanism chosen after a spike.' },
    tasks: { state: 'unverified', how: 'A cgroup v2 per task, enforced with nftables or eBPF.' },
  },
];

export const CHECKPOINTS = [
  ['P0-01', 'Policy before execution'],
  ['P0-02', 'Real deny'],
  ['P0-03', 'Small explicit allow'],
  ['P0-04', 'Authorized change'],
  ['P0-05', 'Bounded session grant'],
  ['P0-06', 'Fault and recovery'],
  ['P0-07', 'Useful fx contract'],
  ['P0-08', 'Second-platform evidence'],
  ['P0-09', 'Forwardable proof'],
  ['P0-10', 'Release gap visible'],
];

export const INVARIANTS = [
  'A strict command starts only after its exact policy generation and required capabilities are armed.',
  'Widening needs an independent, authorized owner. Untrusted code cannot approve its own escape.',
  'Effective permission is the intersection of every ceiling that applies. A narrower scope cannot erase a mandatory deny.',
  'No model or remote service takes part in an enforcement verdict.',
  'If a policy needs semantics a backend cannot enforce, activation fails. Missing identity never satisfies an allow.',
  'A domain rule names its evidence, destination binding, protocol and limits. DNS is part of the boundary.',
  'An update commits as one acknowledged generation. Errors never leave a partial policy.',
  'Temporary access ends locally at its earliest bound. What a revocation covers is explicit.',
  'Gaps in observability are counted. A logging failure never widens access.',
  'Protection and recovery are stated per fault, OS, backend and scope.',
  'The first usable release needs app and task control on both macOS and Linux, each claim backed by evidence.',
  'The local product works without an account or telemetry. Dependencies and exports are explicit.',
];

export const STATE_LABEL = { verified: 'Verified', probe: 'Probes only', unverified: 'Unverified' };
