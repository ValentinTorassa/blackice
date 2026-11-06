/* Figure captions, shared by the SVG diagrams and the markdown twins so the
   text an agent reads is the text a person reads under the drawing. */
export const figureText = {
  FigArchitecture:
    'The parts. The extension is the only part that allows or drops a connection. The daemon runs the hooks and passes their answers on. A person answers through the CLI or the menu bar, with Touch ID.',
  FigAsk:
    'Ask mode. A connection no rule covers waits while the hook asks an agent, which ends its reply with approve 1h or deny. With no answer before the timeout, the connection is dropped.',
} as const

export const figureLabel = {
  FigArchitecture:
    "Architecture: apps' connections go through the network extension inside Blackice.app. The extension sends events to the blackice daemon, which runs the hook from blackice.toml as blackice start saved it. The agent in the hook answers on its last line of output, and the daemon sends that answer to the extension with the event's token. A person answers through the blackice CLI, with Touch ID.",
  FigAsk:
    'Ask mode: an app opens a connection, the extension pauses it and sends an event to the daemon, the daemon runs the hook, the agent prints approve 1h as its last line, the daemon sends that answer with the event token, and the extension resumes the flow. With no answer in time, the flow is dropped.',
} as const
