export const meta = {
  name: 'aura-polish-fix',
  description: 'Fix audited findings per file-owned package, each agent in its own git worktree, building and testing before committing',
  phases: [{ title: 'Fix', detail: 'one agent per package, isolated worktree, build + tests + commit' }],
}

const ROOT = '/Users/aniko/Documents/Subjected/Aura'
const FILE = args.file
const ORDER = args.order
const COUNTS = args.counts
const OWNERSHIP = args.ownership
const BASE = args.base

const RESULT_SCHEMA = {
  type: 'object',
  properties: {
    package: { type: 'string' },
    worktree: { type: 'string' },
    branch: { type: 'string' },
    head_commit: { type: 'string' },
    build_ok: { type: 'boolean' },
    tests_run: { type: 'string', description: 'the exact -only-testing suites you ran' },
    tests_ok: { type: 'boolean' },
    fixed: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, summary: { type: 'string' } }, required: ['id', 'summary'] } },
    skipped: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, reason: { type: 'string' } }, required: ['id', 'reason'] } },
    files_changed: { type: 'array', items: { type: 'string' } },
    cross_owner_files: { type: 'array', items: { type: 'string' }, description: 'files you edited outside your ownership' },
    notes: { type: 'string', description: 'anything the integrator must know: follow-ups, risks, things to verify by hand in the running app' },
  },
  required: ['package', 'worktree', 'branch', 'head_commit', 'build_ok', 'tests_run', 'tests_ok', 'fixed', 'skipped', 'files_changed', 'cross_owner_files', 'notes'],
}

function prompt(name, count) {
  const own = OWNERSHIP[name] || []
  return `You are fixing audited findings in Aura, a macOS browser (SwiftUI + AppKit + WebKit, Swift 5.9, macOS 15+). You are running inside a dedicated git worktree of the repository on your own branch. The main checkout at ${ROOT} belongs to the integrator: never edit anything there.

FIRST, run:
  pwd; git rev-parse --abbrev-ref HEAD; git log --oneline -3
If pwd is exactly ${ROOT}, stop immediately and return with notes explaining you had no worktree. Otherwise record pwd and the branch for your final report. The worktree was cut from the wrong commit, so move your branch onto the integrator's base before anything else (this is your own branch in your own worktree, so the reset is safe):
  git reset --hard ${BASE}
  git log --oneline -3      # the top must be ${BASE}
Every finding's file and line numbers refer to ${BASE}. Then:
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  xcodegen generate        # Aura.xcodeproj is untracked; every worktree generates it

BUILD (use your own DerivedData so you never collide with other agents):
  xcodebuild build -project Aura.xcodeproj -scheme aura -destination "platform=macOS" -configuration Debug -derivedDataPath /tmp/dd-fix-${name} CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= > /tmp/dd-fix-${name}.build.log 2>&1; grep -E "^\\*\\* BUILD|: error:" /tmp/dd-fix-${name}.build.log | head -20
The full log is huge: always redirect it and grep. A fresh build takes about 30 to 90 seconds.

TESTS:
  xcodebuild build-for-testing -project Aura.xcodeproj -scheme aura -destination "platform=macOS" -configuration Debug -derivedDataPath /tmp/dd-fix-${name} CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= > /tmp/dd-fix-${name}.bft.log 2>&1; grep -E "^\\*\\* |: error:" /tmp/dd-fix-${name}.bft.log | head
  xcodebuild test-without-building -project Aura.xcodeproj -scheme aura -destination "platform=macOS" -derivedDataPath /tmp/dd-fix-${name} -only-testing:auraTests/SomeSuite -only-testing:auraTests/OtherSuite CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= > /tmp/dd-fix-${name}.test.log 2>&1; grep -E "Suite .* (passed|failed)|Test run|error:|failed" /tmp/dd-fix-${name}.test.log | tail -20
Run every suite in auraTests that covers the types you changed (grep auraTests for the type and function names) plus any test you add. Tests use Swift Testing (@Test, #expect) in the newer files and XCTest in older ones; copy the style of the file you extend. Suites named *WebBundleTests, WebRequestBrokerTests and BrowserPageTests need TEST_RUNNER_AURA_BUNDLE=1 in the environment and take about a minute. Do not run the entire suite.

LINT, on the files you changed:
  swiftformat <files>
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swiftlint lint <files>
No new warnings beyond the pre-existing file_length / type_body_length ones.

HARD RULES:
- Never launch the app, never use osascript or any GUI automation, never touch the user's other apps. Build and unit tests only.
- Do not rename Ora* types or files and do not rename the injected script names or window globals; a separate final pass owns those. Do not reformat or "tidy" code you are not changing.
- Smallest correct diff. Reuse the helpers that already exist (grep before writing). No new dependencies, no new abstractions with one caller, no configuration for a value that never changes. Two options the same size: take the one that is right on edge cases.
- Every comment explains why, never what and never history ("used to", "before this change", "now"). Prefer no comment over a narrative one. No em dashes anywhere. UI copy: sentence case for buttons and labels unless the surrounding screen uses Title Case, "…" not "...", straight quotes, no emoji, no trailing period on labels.
- Design: radii come from AuraRadius (button 6, row 10, pane 13), shadows from auraFloatingShadow(), animations from AnimationSettings; custom-looking controls (OraButton, OraInput, InteractiveButtonStyle, DialogManager dialogs, AuraMenu) over stock AppKit/SwiftUI ones. Respect Reduce Motion where motion is added.
- Logging through AuraLog / os.Logger, never print(.
- For a non-trivial logic change (a branch, a parser, a ranking, a lifecycle path) leave one small test behind in auraTests. Trivial one-liners need none.
- If you deliberately simplify with a known ceiling, leave a "// ponytail: <ceiling>, <upgrade trigger>" comment.
- Findings were proposed by one auditor and confirmed by a skeptic, but they can still be wrong. Read the cited code and its callers before changing it. If a finding is wrong, already fixed on this branch, needs a product decision, or its fix would regress something, skip it and give the reason. Several findings are duplicates of each other (same defect found by two auditors): fix once and list every id under fixed.
- Findings whose files_to_touch include files outside your ownership: make the smallest possible change there and list the file under cross_owner_files. Another agent may edit the same file; the integrator merges.

YOUR OWNERSHIP (paths you may freely edit):
${own.map(p => '  ' + p).join('\n')}

COMMIT when done, in the worktree:
  git add -A && git commit -m "<type>: <one-line summary>" -m "<a short paragraph on why, in plain prose>"
Types: fix, polish, perf, a11y, chore. One commit per coherent group is fine (for example one for bugs, one for polish); do not make one commit per finding. No Co-Authored-By lines, no AI attribution. The pre-commit hook runs swiftformat and swiftlint --fix on staged files; if it changes files, run git add -A and commit again. Report the final git rev-parse HEAD.

YOUR FINDINGS (${count} of them) are stored in ${FILE} under packages["${name}"]. Read every one of them in full before starting, for example:
  python3 -c 'import json; [print(json.dumps(f, indent=1)) for f in json.load(open("${FILE}"))["packages"]["${name}"]]'
Each has id, kind, severity, title, file, line, evidence, user_impact, fix (the proposed change, sometimes corrected by the skeptic), files_to_touch, cross_owners and confidence. Work through ALL of them, highest severity first. Your final answer is the structured result only.`
}

const EFFORT = args.effort || {}

phase('Fix')
const results = await parallel(ORDER.map(name => () =>
  agent(prompt(name, COUNTS[name]), {
    label: `fix:${name}`,
    phase: 'Fix',
    schema: RESULT_SCHEMA,
    model: 'opus',
    effort: EFFORT[name] || 'medium',
    isolation: 'worktree',
  }).then(r => {
    if (r) log(`fix:${name}: fixed ${r.fixed.length}, skipped ${r.skipped.length}, build ${r.build_ok ? 'ok' : 'FAILED'}, tests ${r.tests_ok ? 'ok' : 'FAILED'} @ ${r.branch}`)
    else log(`fix:${name}: no result`)
    return r
  })
))
return results.filter(Boolean)
