const { test } = require('node:test')
const assert = require('node:assert/strict')
const { readFileSync, readdirSync } = require('node:fs')
const { join } = require('node:path')

const workflowDir = join(__dirname, '..', '.github', 'workflows')
const files = [
  'build.yaml',
  'clean-up-gh-pages.yaml',
  'gh-pages.yaml',
  'image.yaml',
  'integration-tests.yaml',
  'patrol-web-integration-test.yaml',
  'perf-backfill.yaml',
  'release.yaml',
]

const USES = /^\s*-?\s*uses:\s*([^\s#]+)/gm

test('every GitHub Action in Chat workflows is pinned to a 40-hex SHA', () => {
  for (const file of files) {
    assert.ok(readdirSync(workflowDir).includes(file), `${file}: workflow is missing`)
    const content = readFileSync(join(workflowDir, file), 'utf8')
    for (const match of content.matchAll(USES)) {
      const ref = match[1]
      if (ref.startsWith('./') || ref.startsWith('docker://')) continue
      // Only check third-party and first-party actions (owner/repo@ref)
      if (!ref.includes('/')) continue
      const at = ref.lastIndexOf('@')
      assert.ok(at > 0, `${file}: malformed uses entry "${ref}"`)
      const sha = ref.slice(at + 1)
      assert.match(
        sha,
        /^[0-9a-f]{40}$/,
        `${file}: "${ref}" is not pinned to a 40-hex SHA`,
      )
    }
  }
})
