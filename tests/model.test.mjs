// Runs Model.js under node by stripping the QML-only `.pragma library` line
// and re-exporting its top-level declarations. Keeps Model.js itself free of
// any module syntax the QML engine would reject.
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import assert from "node:assert/strict"

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = new Function(src + "\nreturn {toArray,normalizeDomain,validDomain,normalizeDomains,sanitizeProfile,sanitizeProfiles,findProfile,profileIndex,profileSummary,parseNotifyLine,appMatches,shouldSilence,needsWatcher,usesGlobalDnd,formatCountdown,formatRemaining,expired,durationLabel,defaultProfiles,notifyLabel}")()

let n = 0
const t = (name, fn) => { fn(); n++; }

t("normalizeDomain strips scheme, www, path, port", () => {
  assert.equal(M.normalizeDomain("https://www.Instagram.com/explore?a=1"), "instagram.com")
  assert.equal(M.normalizeDomain("x.com:443"), "x.com")
  assert.equal(M.normalizeDomain("  NEWS.ycombinator.COM  "), "news.ycombinator.com")
  assert.equal(M.normalizeDomain("instagram.com."), "instagram.com")
  assert.equal(M.normalizeDomain("user@reddit.com"), "reddit.com")
})

t("normalizeDomain rejects junk and injection attempts", () => {
  for (const bad of ["", "localhost", "not a domain", "rm -rf /", "a.com; echo hi",
                     "-lead.com", "trail-.com", "a..com", "10.0.0.1 evil.com",
                     "foo.com\nbar.com", "*.foo.com", "foo_bar.com"]) {
    assert.equal(M.normalizeDomain(bad), "", `expected reject: ${JSON.stringify(bad)}`)
    assert.equal(M.validDomain(bad), false)
  }
})

t("normalizeDomains dedupes, sorts, drops rejects", () => {
  assert.deepEqual(
    M.normalizeDomains(["www.x.com", "X.COM", "https://instagram.com/", "bogus", ""]),
    ["instagram.com", "x.com"])
})

t("sanitizeProfile coerces hostile input", () => {
  const p = M.sanitizeProfile({ name: "  ", notify: "wat", domains: ["a.com", "; rm -rf /"],
                                apps: ["Slack", "Slack", " "], defaultMinutes: 99999 })
  assert.equal(p.name, "Focus")
  assert.equal(p.notify, "all")          // unknown mode falls back to the safe one
  assert.deepEqual(p.domains, ["a.com"])
  assert.deepEqual(p.apps, ["Slack"])
  assert.equal(p.defaultMinutes, 0)
})

t("sanitizeProfiles suffixes duplicate names instead of dropping them", () => {
  // Collision detection is case-insensitive (names are IPC addresses), but
  // the suffixed name keeps the casing the user typed.
  const out = M.sanitizeProfiles([{ name: "Work" }, { name: "work" }, { name: "Work" }])
  assert.deepEqual(out.map(p => p.name), ["Work", "work 2", "Work 3"])
  // Every resulting name must be uniquely addressable.
  const keys = out.map(p => p.name.toLowerCase())
  assert.equal(new Set(keys).size, keys.length)
  for (const p of out) assert.equal(M.findProfile(out, p.name).name, p.name)
})

t("sanitizeProfiles falls back to defaults when empty", () => {
  assert.deepEqual(M.sanitizeProfiles([]).map(p => p.name), ["Work", "Personal", "Sleep"])
  assert.deepEqual(M.sanitizeProfiles(null).map(p => p.name), ["Work", "Personal", "Sleep"])
})

t("findProfile is case-insensitive, profileIndex agrees", () => {
  const ps = M.defaultProfiles()
  assert.equal(M.findProfile(ps, "wOrK").name, "Work")
  assert.equal(M.findProfile(ps, "nope"), null)
  assert.equal(M.profileIndex(ps, "sleep"), 2)
  assert.equal(M.profileIndex(ps, "nope"), -1)
})

t("parseNotifyLine splits on the first tab only", () => {
  assert.deepEqual(M.parseNotifyLine("Slack\tNew message"), { appName: "Slack", summary: "New message" })
  assert.deepEqual(M.parseNotifyLine("Slack\ta\tb"), { appName: "Slack", summary: "a\tb" })
  assert.deepEqual(M.parseNotifyLine("Slack\t"), { appName: "Slack", summary: "" })
  assert.equal(M.parseNotifyLine("no-tab"), null)
  assert.equal(M.parseNotifyLine("\tsummary"), null)
  assert.equal(M.parseNotifyLine(""), null)
})

t("appMatches is bidirectional and case-insensitive", () => {
  assert.equal(M.appMatches("Slack", ["slack"]), true)
  assert.equal(M.appMatches("Chrome", ["Google Chrome"]), true)   // entry wider than app
  assert.equal(M.appMatches("Google Chrome", ["Chrome"]), true)   // app wider than entry
  assert.equal(M.appMatches("Signal", ["Slack", "Discord"]), false)
  assert.equal(M.appMatches("", ["Slack"]), false)
  assert.equal(M.appMatches("Slack", [" ", ""]), false)           // blank entries never match
})

t("shouldSilence implements block/allow/all/off", () => {
  const block = { notify: "block", apps: ["Slack"] }
  assert.equal(M.shouldSilence(block, "Slack"), true)
  assert.equal(M.shouldSilence(block, "Signal"), false)

  const allow = { notify: "allow", apps: ["Signal"] }
  assert.equal(M.shouldSilence(allow, "Signal"), false)
  assert.equal(M.shouldSilence(allow, "Slack"), true)

  // "all" is global DND and "off" is a no-op: the watcher never runs for
  // either, so neither may claim a silence here.
  assert.equal(M.shouldSilence({ notify: "all", apps: [] }, "Slack"), false)
  assert.equal(M.shouldSilence({ notify: "off", apps: [] }, "Slack"), false)
  assert.equal(M.shouldSilence(null, "Slack"), false)
})

t("allow-list with no apps silences everything", () => {
  assert.equal(M.shouldSilence({ notify: "allow", apps: [] }, "Anything"), true)
})

t("watcher/DND selection are mutually exclusive", () => {
  for (const [mode, watcher, dnd] of [["off", false, false], ["all", false, true],
                                      ["allow", true, false], ["block", true, false]]) {
    const p = { notify: mode, apps: [] }
    assert.equal(M.needsWatcher(p), watcher, mode)
    assert.equal(M.usesGlobalDnd(p), dnd, mode)
  }
  assert.equal(M.needsWatcher(null), false)
  assert.equal(M.usesGlobalDnd(null), false)
})

t("formatCountdown rounds up and clamps", () => {
  assert.equal(M.formatCountdown(0, 0), "")                    // indefinite
  assert.equal(M.formatCountdown(1000, 0), "0:01")
  assert.equal(M.formatCountdown(60000, 0), "1:00")
  assert.equal(M.formatCountdown(59999, 0), "1:00")            // rounds up, never shows 0:59 early
  assert.equal(M.formatCountdown(3600000, 0), "1:00:00")
  assert.equal(M.formatCountdown(1, 0), "0:01")                // sub-second still reads as running
  assert.equal(M.formatCountdown(5, 10), "0:00")               // already past
  assert.equal(M.formatCountdown(-5000, 0), "0:00")            // a past deadline, not indefinite
  assert.equal(M.formatCountdown(null, 0), "")                 // only null/0 mean indefinite
})

t("formatRemaining formats a held duration", () => {
  assert.equal(M.formatRemaining(0), "0:00")
  assert.equal(M.formatRemaining(-1), "0:00")
  assert.equal(M.formatRemaining(NaN), "0:00")
  assert.equal(M.formatRemaining(1), "0:01")                   // rounds up to the next second
  assert.equal(M.formatRemaining(45000), "0:45")
  assert.equal(M.formatRemaining(23 * 60000 + 10000), "23:10")
  assert.equal(M.formatRemaining(3723000), "1:02:03")
})

t("expired only fires on a real deadline", () => {
  assert.equal(M.expired(0, 100), false)
  assert.equal(M.expired(null, 100), false)
  assert.equal(M.expired(100, 100), true)
  assert.equal(M.expired(101, 100), false)
})

t("durationLabel", () => {
  assert.equal(M.durationLabel(0), "∞")
  assert.equal(M.durationLabel(25), "25m")
  assert.equal(M.durationLabel(60), "1h")
  assert.equal(M.durationLabel(90), "1h30m")
})

t("profileSummary reads as a sentence fragment", () => {
  assert.equal(M.profileSummary({ domains: ["a.com"], notify: "off", apps: [] }), "1 site")
  assert.equal(M.profileSummary({ domains: [], notify: "all", apps: [] }), "no sites · silence all")
  assert.equal(M.profileSummary({ domains: ["a.com", "b.com"], notify: "allow", apps: ["X"] }),
               "2 sites · allow 1")
  // An allow-list with nothing allowed is a silence-all in disguise; say so.
  assert.equal(M.profileSummary({ domains: [], notify: "allow", apps: [] }), "no sites · silence all")
  assert.equal(M.profileSummary(null), "")
})

t("notifyLabel covers every mode", () => {
  assert.equal(M.notifyLabel("off"), "Off")
  assert.equal(M.notifyLabel("all"), "Silence all")
  assert.equal(M.notifyLabel("allow"), "Allow only")
  assert.equal(M.notifyLabel("block"), "Silence some")
})

// Regression: Quickshell's JsonAdapter returns array-LIKE objects, not real
// Arrays. Testing them with Array.isArray() is false, which silently replaced
// every saved profile with the defaults. Everything that takes a list must
// accept this shape.
const arrayLike = (...items) => {
  const o = { length: items.length }
  items.forEach((v, i) => { o[i] = v })
  return o                       // no prototype tricks: Array.isArray(o) === false
}

t("array-like inputs behave exactly like real arrays", () => {
  assert.equal(Array.isArray(arrayLike("a")), false, "fixture must not be a real Array")

  assert.deepEqual(M.toArray(arrayLike("a", "b")), ["a", "b"])
  assert.deepEqual(M.toArray(["a"]), ["a"])
  assert.deepEqual(M.toArray(null), [])
  assert.deepEqual(M.toArray(undefined), [])
  assert.deepEqual(M.toArray({}), [])
  assert.deepEqual(M.toArray("abc"), [], "a string has .length but is not a list here")
  assert.deepEqual(M.toArray({ length: -1 }), [])
  assert.deepEqual(M.toArray({ length: 1.5 }), [])

  // The exact failure that shipped: profiles loaded from disk vanished.
  const loaded = arrayLike(
    { name: "BlockTest", notify: "block", apps: arrayLike("notify-send"), domains: arrayLike("x.com") },
    { name: "Work", notify: "off", apps: arrayLike(), domains: arrayLike() })
  const ps = M.sanitizeProfiles(loaded)
  assert.deepEqual(ps.map(p => p.name), ["BlockTest", "Work"],
    "array-like profiles must survive, not fall back to defaults")
  assert.deepEqual(ps[0].apps, ["notify-send"])
  assert.deepEqual(ps[0].domains, ["x.com"])

  assert.deepEqual(M.normalizeDomains(arrayLike("www.X.com", "bogus")), ["x.com"])
  assert.equal(M.appMatches("Slack", arrayLike("slack")), true)
  assert.equal(M.findProfile(arrayLike({ name: "Work" }), "work").name, "Work")
  assert.equal(M.profileIndex(arrayLike({ name: "A" }, { name: "B" }), "b"), 1)
  assert.equal(M.shouldSilence({ notify: "block", apps: arrayLike("Slack") }, "Slack"), true)
})

console.log(`Model.js: ${n} test groups passed`)
