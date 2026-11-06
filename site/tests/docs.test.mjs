import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { readFile } from 'node:fs/promises'
import { createServer } from 'node:net'
import test from 'node:test'

// Run after `npm run build`; exercise Next's actual routing and metadata output.
test('production documentation metadata, Markdown exports and HTML 404s', { timeout: 30_000 }, async (t) => {
  const reservation = createServer()
  reservation.listen(0, '127.0.0.1')
  await once(reservation, 'listening')
  const { port } = reservation.address()
  await new Promise((resolve) => reservation.close(resolve))

  const server = spawn(process.execPath, [
    'node_modules/next/dist/bin/next', 'start', '--hostname', '127.0.0.1', '--port', String(port),
  ], { stdio: ['ignore', 'pipe', 'pipe'] })
  let logs = ''
  server.stdout.on('data', (chunk) => { logs += chunk })
  server.stderr.on('data', (chunk) => { logs += chunk })
  t.after(async () => {
    if (server.exitCode !== null || server.signalCode !== null) return
    const exited = once(server, 'exit')
    server.kill('SIGTERM')
    await exited
  })

  for (let i = 0; !logs.includes('Ready in'); i++) {
    assert.equal(server.exitCode, null, logs)
    assert.ok(i < 150, `Next did not start: ${logs}`)
    await new Promise((resolve) => setTimeout(resolve, 100))
  }

  async function request(path) {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
      headers: { Accept: 'text/html' },
      signal: AbortSignal.timeout(5000),
    })
    return { response, body: await response.text() }
  }

  function meta(html, name) {
    const value = html.match(new RegExp(`<meta (?:property|name)="${name}" content="([^"]*)"`))?.[1]
    assert.ok(value, `Missing metadata: ${name}`)
    return value
  }

  const pages = [
    ['/docs', 'Introduction', '/docs.md'],
    ['/docs/install', 'Install', '/docs/install.md'],
    ['/docs/configuration', 'Configuration', '/docs/configuration.md'],
    ['/docs/cli', 'CLI', '/docs/cli.md'],
  ]
  for (const [path, title, markdownPath] of pages) {
    const { response, body } = await request(path)
    assert.equal(response.status, 200, path)
    assert.match(response.headers.get('content-type'), /text\/html/)
    assert.equal(meta(body, 'og:title'), title)
    assert.equal(meta(body, 'twitter:title'), title)
    assert.equal(new URL(meta(body, 'og:url')).pathname, path)
    assert.equal(meta(body, 'og:description'), meta(body, 'description'))
    assert.equal(meta(body, 'twitter:description'), meta(body, 'description'))

    const markdown = await request(markdownPath)
    assert.equal(markdown.response.status, 200, markdownPath)
    assert.match(markdown.response.headers.get('content-type'), /text\/markdown/)
    assert.ok(markdown.body.startsWith(`# ${title}\n`), markdownPath)
    assert.doesNotMatch(markdown.body, /getDocsMetadata|export const metadata|<Status\s*\/>/)
  }

  // Removed pages still lead somewhere.
  const changelog = 'https://github.com/ValentinTorassa/blackice/blob/main/CHANGELOG.md'
  for (const [path, location] of [
    ['/docs/how-it-works', '/docs'],
    ['/docs/how-it-works.md', '/docs.md'],
    ['/docs/changelog', changelog],
    ['/docs/changelog.md', changelog],
  ]) {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, { redirect: 'manual', signal: AbortSignal.timeout(5000) })
    assert.equal(response.status, 307, path)
    assert.equal(new URL(response.headers.get('location'), `http://127.0.0.1:${port}`).href, new URL(location, `http://127.0.0.1:${port}`).href, path)
  }

  for (const path of ['/docs/missing', '/docs/missing/nested', '/missing']) {
    const { response, body } = await request(path)
    assert.equal(response.status, 404, path)
    assert.match(response.headers.get('content-type'), /text\/html/)
    assert.match(body, /Page not found/)
  }
  for (const path of ['/docs/missing.md', '/docs/missing/nested.md']) {
    const { response } = await request(path)
    assert.equal(response.status, 404, path)
    assert.match(response.headers.get('content-type'), /text\/markdown/)
  }

  const full = await request('/llms-full.txt')
  assert.equal(full.response.status, 200)
  assert.match(full.response.headers.get('content-type'), /text\/plain/)
  for (const [, title] of pages) assert.ok(full.body.includes(`# ${title}\n`))
  assert.doesNotMatch(full.body, /getDocsMetadata|export const metadata/)

  const manifest = JSON.parse(await readFile('.next/prerender-manifest.json', 'utf8'))
  for (const path of ['/docs.md', '/llms-full.txt', '/markdown/docs/cli', '/markdown/docs/configuration', '/markdown/docs/install']) {
    assert.ok(manifest.routes[path], `Not prerendered: ${path}`)
  }
})
