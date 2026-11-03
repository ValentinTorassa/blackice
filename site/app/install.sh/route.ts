import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { markdownResponse } from '@/lib/docs-markdown'
import { release } from '@/lib/release'

/* `curl -fsSL https://blackice-macos.vercel.app/install.sh | sh` runs lib/install.sh. The script
   pins the release it installs, so the build fails when that differs from lib/release.ts. */
async function getInstallScript(): Promise<string> {
  'use cache'

  const script = await readFile(join(process.cwd(), 'lib/install.sh'), 'utf8')
  const pinned = /^VERSION=(\S+)$/m.exec(script)?.[1]
  if (pinned !== release.version) {
    throw new Error(`lib/install.sh installs ${pinned ?? 'no version'}, but lib/release.ts says ${release.version}`)
  }
  return script
}

export async function GET() {
  return markdownResponse(await getInstallScript(), { contentType: 'text/plain; charset=utf-8' })
}
