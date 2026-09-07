export const meta = {
  name: 'aura-polish-review',
  description: 'Adversarial review of the merged polish diff: independent reviewers per file group, then a skeptic per group',
  phases: [
    { title: 'Review', detail: 'one reviewer per file group reads the diff and the surrounding code' },
    { title: 'Verify', detail: 'one skeptic per group tries to refute each issue' },
  ],
}

const ROOT = '/Users/aniko/Documents/Subjected/Aura'
const BASE = args.base
const GROUPS = args.groups // [{key, files: [...]}]

const ISSUES_SCHEMA = {
  type: 'object',
  properties: {
    group: { type: 'string' },
    issues: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          title: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'integer' },
          evidence: { type: 'string' },
          failure: { type: 'string', description: 'concrete input or state that produces the wrong behaviour' },
          fix: { type: 'string' },
          confidence: { type: 'number' },
        },
        required: ['id', 'severity', 'title', 'file', 'line', 'evidence', 'failure', 'fix', 'confidence'],
      },
    },
  },
  required: ['group', 'issues'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          real: { type: 'boolean' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          reason: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['id', 'real', 'severity', 'reason', 'fix'],
      },
    },
  },
  required: ['verdicts'],
}

const PRE = `Aura is a macOS browser (SwiftUI + AppKit + WebKit, Swift 5.9, macOS 15+) at ${ROOT}. A polish pass by several agents landed as commits on the current branch; the diff since ${BASE} is what you review. READ-ONLY: do not edit, build or run anything; no osascript. Use git and grep from ${ROOT}:
  git diff ${BASE}..HEAD --stat
  git diff ${BASE}..HEAD -- <file>
  git log --oneline ${BASE}..HEAD
Read the changed hunks AND the code around them (callers, the whole function, related tests). You are looking for defects the polish pass introduced or left half-done: crashes, wrong behaviour, regressions of behaviour that worked at ${BASE}, main-actor or lifecycle mistakes, leaks of monitors/observers, retain cycles, private-browsing data reaching shared stores, copy that is now inconsistent, a fix that only covers one of several callers, tests that do not test what they claim, comments that narrate history, em dashes, print( calls, stock controls added next to custom ones, radii or shadows off the AuraRadius/auraFloatingShadow scale. Report only what you verified in the code, with exact file and line in the CURRENT tree. Your final answer is the structured result only.`

function reviewPrompt(g) {
  return `${PRE}

GROUP ${g.key}. Files in this group (review the diff of every one of them):
${g.files.map(f => '  ' + f).join('\n')}

Use ids ${g.key}-1, ${g.key}-2, ... Sort by severity.`
}

function verifyPrompt(g, found) {
  return `${PRE}

You are the skeptic for GROUP ${g.key}. Try to REFUTE each issue below: open the file, read the surrounding code and callers, check whether the behaviour really is wrong in the current tree and really is user-visible or a genuine defect. Keep real=true only for what you confirmed; when in doubt, real=false with the reason. Correct the fix where the proposed one is wrong or too large.

ISSUES:
${JSON.stringify(found.issues, null, 1)}`
}

phase('Review')
const results = await pipeline(
  GROUPS,
  g => agent(reviewPrompt(g), { label: `review:${g.key}`, phase: 'Review', schema: ISSUES_SCHEMA, model: 'opus', effort: 'high' }),
  (found, g) => {
    if (!found || !found.issues.length) { log(`review:${g.key}: clean`); return { group: g.key, confirmed: [], refuted: [] } }
    log(`review:${g.key}: ${found.issues.length} issues, verifying`)
    return agent(verifyPrompt(g, found), { label: `verify:${g.key}`, phase: 'Verify', schema: VERDICT_SCHEMA, model: 'opus', effort: 'high' })
      .then(v => {
        const by = new Map(((v && v.verdicts) || []).map(x => [x.id, x]))
        const confirmed = [], refuted = []
        for (const i of found.issues) {
          const x = by.get(i.id)
          if (x && x.real) confirmed.push({ ...i, severity: x.severity, fix: x.fix || i.fix, verify_reason: x.reason })
          else refuted.push({ id: i.id, title: i.title, reason: x ? x.reason : 'no verdict' })
        }
        log(`${g.key}: ${confirmed.length} confirmed, ${refuted.length} refuted`)
        return { group: g.key, confirmed, refuted }
      })
  },
)
return results.filter(Boolean)
