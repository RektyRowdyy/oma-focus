.pragma library

// Pure helpers for oma-focus. No QML imports, no side effects — everything
// here is a function of its arguments, so it can be reasoned about (and
// exercised with `qjs Model.js`) without a running shell.

// --- array coercion ---------------------------------------------------

// Quickshell's JsonAdapter hands back array-LIKE objects, not true JS Arrays:
// they index and have .length, but Array.isArray() is false for them. Testing
// with Array.isArray here silently threw away every profile the user had ever
// saved and replaced it with the defaults, so everything below goes through
// this instead. Returns a real Array, always safe to iterate and .concat().
function toArray(value) {
  if (Array.isArray(value)) return value
  if (value === null || value === undefined) return []
  if (typeof value === "string") return []
  var len = value.length
  if (typeof len !== "number" || len < 0 || len !== Math.floor(len)) return []
  var out = []
  for (var i = 0; i < len; i++) out.push(value[i])
  return out
}

// --- domains ----------------------------------------------------------

// The single source of truth for what counts as a blockable domain. The
// privileged helper re-validates with the same pattern before it touches
// /etc/hosts; this copy exists so the panel can reject bad input before it
// ever reaches root, not as the security boundary.
var DOMAIN_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/

// Accepts what people actually paste — a full URL, a leading "www.", a
// trailing slash, mixed case — and reduces it to the registrable host.
// Returns "" for anything that cannot be salvaged, so callers test one thing.
function normalizeDomain(raw) {
  var s = String(raw || "").trim().toLowerCase()
  if (!s) return ""
  s = s.replace(/^[a-z][a-z0-9+.-]*:\/\//, "")  // scheme
  s = s.replace(/^[^/@]*@/, "")                  // userinfo
  s = s.split("/")[0].split("?")[0].split("#")[0]
  s = s.split(":")[0]                            // port
  s = s.replace(/^www\./, "")
  s = s.replace(/\.$/, "")                       // root-label dot
  return DOMAIN_RE.test(s) ? s : ""
}

function validDomain(raw) {
  return normalizeDomain(raw) !== ""
}

// Normalizes, drops rejects, de-duplicates, sorts. Sorting keeps the panel
// list and the written /etc/hosts block stable, so a no-op re-apply produces
// a byte-identical file and nothing churns.
function normalizeDomains(list) {
  var seen = ({})
  var out = []
  var arr = toArray(list)
  for (var i = 0; i < arr.length; i++) {
    var d = normalizeDomain(arr[i])
    if (!d || seen[d]) continue
    seen[d] = true
    out.push(d)
  }
  return out.sort()
}

// --- profiles ---------------------------------------------------------

// notify policies:
//   "off"   leave notifications alone
//   "all"   global DND — the daemon suppresses everything, nothing flashes
//   "allow" silence everything except `apps` (Apple's "Allowed Notifications")
//   "block" silence only `apps`
var NOTIFY_MODES = ["off", "all", "allow", "block"]

function notifyLabel(mode) {
  switch (String(mode || "off")) {
  case "all": return "Silence all"
  case "allow": return "Allow only"
  case "block": return "Silence some"
  default: return "Off"
  }
}

function defaultProfiles() {
  return [
    {
      name: "Work",
      domains: ["instagram.com", "reddit.com", "x.com", "youtube.com"],
      notify: "allow",
      apps: ["Google Calendar", "Slack"],
      defaultMinutes: 50
    },
    {
      name: "Personal",
      domains: ["linkedin.com", "news.ycombinator.com"],
      notify: "block",
      apps: ["Slack"],
      defaultMinutes: 25
    },
    {
      name: "Sleep",
      domains: ["instagram.com", "reddit.com", "x.com", "youtube.com"],
      notify: "all",
      apps: [],
      defaultMinutes: 0
    }
  ]
}

// Coerces anything loaded from disk into the shape the rest of the code
// assumes. A hand-edited profiles.json must never be able to crash the
// service or, worse, smuggle a non-domain through to the helper.
function sanitizeProfile(raw, fallbackName) {
  var p = (raw && typeof raw === "object") ? raw : ({})
  var name = String(p.name || fallbackName || "Focus").trim() || "Focus"
  var notify = NOTIFY_MODES.indexOf(String(p.notify)) !== -1 ? String(p.notify) : "all"
  var apps = []
  var rawApps = toArray(p.apps)
  for (var i = 0; i < rawApps.length; i++) {
    var a = String(rawApps[i] || "").trim()
    if (a && apps.indexOf(a) === -1) apps.push(a)
  }
  var mins = Math.floor(Number(p.defaultMinutes))
  if (!isFinite(mins) || mins < 0 || mins > 1440) mins = 0
  return {
    name: name,
    domains: normalizeDomains(p.domains),
    notify: notify,
    apps: apps,
    defaultMinutes: mins
  }
}

function sanitizeProfiles(raw) {
  var arr = toArray(raw)
  if (!arr.length) return defaultProfiles()
  var out = []
  var seen = ({})
  for (var i = 0; i < arr.length; i++) {
    var p = sanitizeProfile(arr[i], "Focus " + (i + 1))
    // Profiles are addressed by name over IPC, so duplicates would make
    // `focus on <name>` ambiguous. Suffix rather than drop — losing a
    // user's profile to silently fix a collision would be worse. Keyed
    // case-insensitively to match findProfile: "Work" and "work" are the
    // same address, so they have to be disambiguated here too.
    var base = p.name
    var n = 2
    while (seen[p.name.toLowerCase()]) p.name = base + " " + (n++)
    seen[p.name.toLowerCase()] = true
    out.push(p)
  }
  return out
}

function findProfile(profiles, name) {
  var arr = toArray(profiles)
  var needle = String(name || "").trim().toLowerCase()
  if (!needle) return null
  for (var i = 0; i < arr.length; i++)
    if (String(arr[i].name || "").toLowerCase() === needle) return arr[i]
  return null
}

function profileIndex(profiles, name) {
  var arr = toArray(profiles)
  var needle = String(name || "").trim().toLowerCase()
  for (var i = 0; i < arr.length; i++)
    if (String(arr[i].name || "").toLowerCase() === needle) return i
  return -1
}

// One-line "what this profile does", for the panel row and the tooltip.
function profileSummary(profile) {
  if (!profile) return ""
  var parts = []
  var n = profile.domains ? profile.domains.length : 0
  parts.push(n === 0 ? "no sites" : (n + (n === 1 ? " site" : " sites")))
  switch (String(profile.notify || "off")) {
  case "all": parts.push("silence all"); break
  case "allow":
    parts.push((profile.apps && profile.apps.length)
      ? "allow " + profile.apps.length : "silence all")
    break
  case "block":
    if (profile.apps && profile.apps.length) parts.push("silence " + profile.apps.length)
    break
  }
  return parts.join(" · ")
}

// --- notification matching -------------------------------------------

// One line of `oma-focus-notifywatch` output: "appName\tsummary".
// Returns null for anything malformed so the caller can skip it.
function parseNotifyLine(line) {
  var s = String(line || "")
  if (!s) return null
  var tab = s.indexOf("\t")
  if (tab === -1) return null
  var app = s.slice(0, tab).trim()
  var summary = s.slice(tab + 1).trim()
  if (!app) return null
  return { appName: app, summary: summary }
}

// Case-insensitive substring match in either direction: an entry of "slack"
// should catch "Slack", and an entry of "Google Chrome" should catch the
// "Chrome" a sender actually reports. Deliberately forgiving — the user is
// typing app names from memory, not writing regexes.
function appMatches(appName, list) {
  var app = String(appName || "").toLowerCase()
  if (!app) return false
  var arr = toArray(list)
  for (var i = 0; i < arr.length; i++) {
    var entry = String(arr[i] || "").trim().toLowerCase()
    if (!entry) continue
    if (app.indexOf(entry) !== -1 || entry.indexOf(app) !== -1) return true
  }
  return false
}

// The watcher only runs for "allow"/"block"; "all" is handled by global DND
// and "off" by doing nothing, so both answer false here.
function shouldSilence(profile, appName) {
  if (!profile) return false
  switch (String(profile.notify || "off")) {
  case "block": return appMatches(appName, profile.apps)
  case "allow": return !appMatches(appName, profile.apps)
  default: return false
  }
}

function needsWatcher(profile) {
  if (!profile) return false
  var m = String(profile.notify || "off")
  return m === "allow" || m === "block"
}

function usesGlobalDnd(profile) {
  return !!profile && String(profile.notify || "off") === "all"
}

// --- time -------------------------------------------------------------

// Counts up to the next whole second so the bar never shows "0:00" while
// still running. Returns "" when there is no deadline (indefinite focus).
function formatCountdown(endsAt, now) {
  if (!endsAt) return ""
  return formatRemaining(Number(endsAt) - Number(now))
}

// The same clock for a duration held still, as a paused session's time left is.
function formatRemaining(ms) {
  ms = Number(ms)
  if (!isFinite(ms) || ms <= 0) return "0:00"
  var total = Math.ceil(ms / 1000)
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  function pad(v) { return v < 10 ? "0" + v : String(v) }
  return h > 0 ? (h + ":" + pad(m) + ":" + pad(s)) : (m + ":" + pad(s))
}

function expired(endsAt, now) {
  return !!endsAt && Number(endsAt) <= Number(now)
}

var DURATION_CHOICES = [
  { minutes: 25, label: "25m" },
  { minutes: 50, label: "50m" },
  { minutes: 60, label: "1h" },
  { minutes: 0, label: "∞" }
]

function durationLabel(minutes) {
  var m = Math.floor(Number(minutes))
  if (!isFinite(m) || m <= 0) return "∞"
  if (m % 60 === 0) return (m / 60) + "h"
  if (m > 60) return Math.floor(m / 60) + "h" + (m % 60) + "m"
  return m + "m"
}
