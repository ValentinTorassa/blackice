/* Figure captions, shared by the SVG diagrams and the markdown twins so the
   text an agent reads is the text a person reads under the drawing. */
export const figureText = {
  FigArchitecture:
    'The parts. The extension sees every new connection on the Mac and is the only part that allows or drops one. It cannot start processes, so a user-level daemon runs the hooks. Answers go back to the extension through the CLI.',
  FigAsk:
    "Ask mode. A connection that no rule or approval covers waits while the hook asks an agent. The agent answers with blackice approve or deny and the event's one-time token. With no answer before the timeout, the connection is dropped.",
} as const

export const figureLabel = {
  FigArchitecture:
    "Architecture: apps' connections go through the network extension inside Blackice.app. The extension sends events to the blackice daemon, which runs the hook from blackice.toml as blackice start saved it. The agent in the hook answers through the blackice CLI, which talks to the extension.",
  FigAsk:
    'Ask mode: an app opens a connection, the extension pauses it and sends an event to the daemon, the daemon runs the hook, the agent runs blackice approve with the event token, and the extension resumes the flow. With no answer in time, the flow is dropped.',
} as const
