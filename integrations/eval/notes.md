These are the tools I use every day. Approve them for what is written here.

- mailctl, my mail CLI, runs as uv's python3 with the script /Users/me/.local/bin/mailctl. It signs
  in and reads mail at oauth2.googleapis.com, gmail.googleapis.com and outlook.office365.com, and
  summarizes mail through ai-gateway.vercel.sh.
- relay, a tool I built, at /Users/me/.local/bin/relay, and curl reach my NAS, nas.tail0abc12.ts.net,
  on port 8771. That is my tailnet, tail0abc12.ts.net, and the NAS is on it at a 100.64.0.0/10
  address.
- My update script runs curl to downloads.claude.ai, releases.openai.com, downloads.cursor.com and
  opencode.ai to fetch new releases.
