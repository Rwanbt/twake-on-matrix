const { test } = require('node:test')
const assert = require('node:assert/strict')
const { readFileSync } = require('node:fs')
const { join } = require('node:path')

const read = name => readFileSync(
  join(__dirname, '..', '.github', 'workflows', name),
  'utf8'
)
const tests = read('tests.yaml')

test('untrusted Chat analysis has no GitHub write token, SSH private keys or persistent checkout credentials', () => {
  assert.match(tests, /^permissions:\s*\r?\n  contents: read\s*$/m)
  assert.doesNotMatch(tests, /\b(contents|actions|checks|pull-requests): write\b/)
  assert.doesNotMatch(tests, /\bsecrets\.SSH_KEY\b|webfactory\/ssh-agent/)
  assert.doesNotMatch(tests, /\bcontinue-on-error: true\b/)
  const checkouts = [...tests.matchAll(/^\s*-?\s*uses: actions\/checkout@([^\s]+)/gm)]
  assert.ok(checkouts.length >= 2)
  for (const [, sha] of checkouts) assert.match(sha, /^[0-9a-f]{40}$/)
  assert.equal((tests.match(/persist-credentials: false/g) || []).length, checkouts.length)
})

test('Chat analyzer and widget test gates always run on pull requests', () => {
  assert.match(tests, /^on:\s*\r?\n  pull_request:\s*\r?\n/m)
  assert.match(tests, /run: \.\/scripts\/code_analyze\.sh/)
  assert.match(tests, /\bflutter test\b/)
  assert.match(tests, /\bflutter analyze\b|run: \.\/scripts\/code_analyze\.sh/)
  assert.match(tests, /flutter-version: \$\{\{ env\.FLUTTER_VERSION \}\}/)
})

test('preview builds must reject fork heads before accessing deployment write credentials', () => {
  const preview = read('gh-pages.yaml')
  assert.match(preview, /^\s+if: \$\{\{ github\.event\.pull_request\.head\.repo\.full_name == github\.repository \}\}/m)
  assert.match(preview, /pull_request:/)
  assert.match(preview, /github_token: \$\{\{ secrets\.GITHUB_TOKEN \}\}/)
})
