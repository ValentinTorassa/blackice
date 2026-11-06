import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { markdownResponse } from '@/lib/docs-markdown'
import { release } from '@/lib/release'

/* `curl -fsSL https://blackice-macos.vercel.app/install.sh | sh` runs lib/install.sh. The script
   pins the release it installs and its zip's SHA-256, so the build fails when the version differs
   from lib/release.ts or the SHA-256 is missing. */
async function getInstallScript(): Promise<string> {
  'use cache'

  const script = await readFile(join(process.cwd(), 'lib/install.sh'), 'utf8')
  const pinned = /^VERSION=(\S+)$/m.exec(script)?.[1]
  if (pinned !== release.version) {
    throw new Error(`lib/install.sh installs ${pinned ?? 'no version'}, but lib/release.ts says ${release.version}`)
  }
  if (!/^SHA256=[0-9a-f]{64}$/m.test(script)) {
    throw new Error(`lib/install.sh pins no SHA-256 for Blackice-${release.version}.zip: set its SHA256 line`)
  }
  return script
}

export async function GET() {
  return markdownResponse(await getInstallScript(), { contentType: 'text/plain; charset=utf-8' })
}
