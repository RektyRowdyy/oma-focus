import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// oma-focus, the singleton half.
//
// The bar renders one widget instance per monitor, but a focus session is one
// global fact about the machine: one /etc/hosts block, one DND setting, one
// deadline. So every piece of state and every side effect lives here, in the
// service-kind entry point the shell mounts exactly once, and BarWidget.qml /
// Panel.qml are views that call in. Nothing below may be moved into the
// widget without it firing once per display.
//
// A third-party service is created with no visual parent (shell.qml), so this
// is strictly headless — no Item children that expect to be rendered.
Item {
  id: root

  // Injected by omarchy-shell when the property exists.
  property var shell: null
  property var manifest: ({})

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: root.home + "/.config/omarchy/oma-focus"
  readonly property string stateDir: root.home + "/.local/state/omarchy/oma-focus"
  readonly property string profilesPath: root.configDir + "/profiles.json"
  readonly property string statePath: root.stateDir + "/state.json"
  readonly property var procEnv: ({ "HOME": root.home })

  function scriptPath(name) {
    var u = Qt.resolvedUrl("bin/" + name).toString()
    return u.startsWith("file://") ? u.slice(7) : u
  }
  readonly property string blockScript: root.scriptPath("oma-focus-block")
  readonly property string watchScript: root.scriptPath("oma-focus-notifywatch")

  // --- live state -------------------------------------------------------

  property var profiles: Model.defaultProfiles()
  // Profiles are addressed by name, not index, so a reordering edit can't
  // silently retarget a running session.
  property string activeName: ""
  property double endsAt: 0
  // The DND value in force before this session turned it on, so "off" can put
  // the user's own setting back rather than assuming off.
  property string savedDnd: ""
  // A paused session is a break: the profile stays selected, but the block and
  // the silencing are lifted and the clock is held at pausedRemaining.
  property bool paused: false
  property double pausedRemaining: 0
  // The session's full length, which rewinding never goes past.
  property double totalMs: 0

  property bool storesReady: false
  property bool busy: false
  property string lastError: ""
  // False until the privileged helper has been installed by scripts/setup.sh.
  property bool setupDone: true

  // Ticks only while a deadline is pending; the countdown binds to it.
  property double now: Date.now()

  readonly property var activeProfile: root.activeName
    ? Model.findProfile(root.profiles, root.activeName) : null
  readonly property bool active: !!root.activeProfile
  readonly property bool running: root.active && !root.paused
  readonly property bool timed: root.active && (root.paused ? root.pausedRemaining > 0 : root.endsAt > 0)
  readonly property double remainingMs: !root.timed ? 0
    : (root.paused ? root.pausedRemaining : Math.max(0, root.endsAt - root.now))
  readonly property string countdown: !root.active ? ""
    : (root.paused ? (root.timed ? Model.formatRemaining(root.pausedRemaining) : "")
                   : Model.formatCountdown(root.endsAt, root.now))

  readonly property string statusLine: {
    if (!root.active) return "Focus off"
    var s = (root.paused ? "Focus paused: " : "Focus: ") + root.activeProfile.name
    if (root.countdown) s += " · " + root.countdown + " left"
    return s
  }

  signal activated(string name)
  signal deactivated()
  signal failed(string message)

  // --- persistence ------------------------------------------------------
  //
  // Two stores, following Omarchy's own split: profiles are user configuration
  // under ~/.config/omarchy, the running session is volatile state under
  // ~/.local/state/omarchy (where both notification daemons keep theirs).
  // They are not merged because a corrupt session must never be able to cost
  // the user their profiles.

  Process {
    id: ensureDirs
    environment: root.procEnv
    command: ["bash", "-c",
      "mkdir -p \"$HOME/.config/omarchy/oma-focus\" \"$HOME/.local/state/omarchy/oma-focus\"; "
      + "f=\"$HOME/.config/omarchy/oma-focus/profiles.json\"; [ -f \"$f\" ] || printf '{}\\n' > \"$f\"; "
      + "s=\"$HOME/.local/state/omarchy/oma-focus/state.json\"; [ -f \"$s\" ] || printf '{}\\n' > \"$s\""]
    onExited: function (exitCode) {
      if (exitCode !== 0) console.warn("oma-focus: could not create state directories (exit " + exitCode + ")")
      profilesFile.reload()
      stateFile.reload()
    }
  }

  FileView {
    id: profilesFile
    path: root.profilesPath
    printErrors: false
    atomicWrites: true
    onLoaded: root.loadProfiles()
    onLoadFailed: root.loadProfiles()
    JsonAdapter {
      id: profilesAdapter
      property var profiles: []
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    printErrors: false
    atomicWrites: true
    onLoaded: root.loadState()
    onLoadFailed: root.loadState()
    JsonAdapter {
      id: stateAdapter
      property string activeName: ""
      property double endsAt: 0
      property string savedDnd: ""
      property bool paused: false
      property double pausedRemaining: 0
      property double totalMs: 0
    }
  }

  function loadProfiles() {
    var raw = profilesAdapter.profiles
    root.profiles = Model.sanitizeProfiles(raw)
    // Write the starter set out on first run, so profiles.json is a real file
    // the user can open and edit rather than an empty stub whose contents only
    // exist in memory. Guarded on emptiness: a load that genuinely returned
    // profiles must never be overwritten.
    if (Model.toArray(raw).length === 0) root.saveProfiles()
    root.markStoreReady()
  }

  function saveProfiles() {
    profilesAdapter.profiles = root.profiles
    profilesFile.writeAdapter()
  }

  function loadState() {
    root.activeName = String(stateAdapter.activeName || "")
    root.endsAt = Number(stateAdapter.endsAt) || 0
    root.savedDnd = String(stateAdapter.savedDnd || "")
    root.paused = stateAdapter.paused === true
    root.pausedRemaining = Math.max(0, Number(stateAdapter.pausedRemaining) || 0)
    root.totalMs = Math.max(0, Number(stateAdapter.totalMs) || 0)
    root.markStoreReady()
  }

  function saveState() {
    stateAdapter.activeName = root.activeName
    stateAdapter.endsAt = root.endsAt
    stateAdapter.savedDnd = root.savedDnd
    stateAdapter.paused = root.paused
    stateAdapter.pausedRemaining = root.pausedRemaining
    stateAdapter.totalMs = root.totalMs
    stateFile.writeAdapter()
  }

  // Both files must have answered before reconcile runs, or a slow profiles
  // load would make a live session look like it names a profile that no
  // longer exists and get torn down for nothing.
  property int storesLoaded: 0
  function markStoreReady() {
    root.storesLoaded += 1
    if (root.storesLoaded >= 2 && !root.storesReady) {
      root.storesReady = true
      Qt.callLater(root.reconcile)
    }
  }

  // --- reconcile on startup --------------------------------------------
  //
  // The fail-safe. A shell crash, a reboot mid-session, or a deadline that
  // passed while the machine was asleep all leave the world blocked with
  // nothing running to unblock it. Whatever the recorded state says, make
  // the machine agree with it before anyone can click anything.

  function reconcile() {
    root.now = Date.now()

    if (root.activeName && !Model.findProfile(root.profiles, root.activeName)) {
      console.warn("oma-focus: active profile '" + root.activeName + "' no longer exists; ending focus")
      root.deactivate()
      return
    }
    if (root.paused && root.active) {
      // Mid-break: the clock is held, so nothing has expired, and the machine
      // should be as free as it was when the pause began.
      tick.running = false
      root.applyBlock([])
      root.clearNotifications()
      root.saveState()
      return
    }
    if (root.active && Model.expired(root.endsAt, root.now)) {
      root.deactivate()
      return
    }
    if (root.active) {
      // Re-assert rather than trust: the shell may have been restarted after
      // someone edited /etc/hosts by hand, and the deadline still stands.
      root.applyBlock(root.activeProfile.domains)
      root.applyNotifications(root.activeProfile)
      tick.running = root.endsAt > 0
      return
    }
    // Not active: make sure nothing is left over from a previous life —
    // neither a block on disk nor a watcher a killed shell left behind.
    root.sweepWatchers()
    statusProbe.running = true
  }

  // Reads the block currently on disk without escalating, so a stale block
  // can be detected on every start for free.
  Process {
    id: statusProbe
    environment: root.procEnv
    command: [root.blockScript, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.trim() !== "") {
          console.warn("oma-focus: found a stale block from a previous session; clearing it")
          root.applyBlock([])
        }
      }
    }
  }

  // --- the privileged helper -------------------------------------------

  property var pendingDomains: null
  property bool blockInFlight: false

  // Serialized: two overlapping helper runs would race on /etc/hosts, and the
  // loser's copy of the file would not contain the winner's block. Only the
  // most recent request is worth keeping, so the queue holds one.
  function applyBlock(domains) {
    root.pendingDomains = Model.normalizeDomains(domains)
    if (root.blockInFlight) return
    root.runNextBlock()
  }

  function runNextBlock() {
    if (root.pendingDomains === null) return
    var domains = root.pendingDomains
    root.pendingDomains = null
    root.blockInFlight = true
    root.busy = true
    blockProc.command = domains.length
      ? [root.blockScript, "on"].concat(domains)
      : [root.blockScript, "off"]
    blockProc.running = true
  }

  Process {
    id: blockProc
    environment: root.procEnv
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.noteHelperError(text.trim())
    }
    onExited: function (exitCode) {
      root.blockInFlight = false
      root.busy = false
      if (exitCode === 0) {
        root.lastError = ""
        root.setupDone = true
        root.refreshChromiumPolicy()
      }
      root.runNextBlock()
    }
  }

  function noteHelperError(message) {
    // The one failure worth distinguishing: the plugin is installed but the
    // privileged helper is not, which is a setup step rather than a fault.
    if (message.indexOf("is not installed") !== -1) {
      root.setupDone = false
      root.lastError = "Run scripts/setup.sh to enable site blocking"
    } else {
      root.lastError = message.split("\n")[0]
    }
    console.warn("oma-focus:", message)
    root.failed(root.lastError)
  }

  // Chromium re-reads managed policy on this signal, so a block takes effect
  // in already-open windows. Run as the user, never from the root helper.
  function refreshChromiumPolicy() {
    var browsers = ["chromium", "google-chrome-stable"]
    for (var i = 0; i < browsers.length; i++) {
      Quickshell.execDetached(["bash", "-c",
        "command -v " + browsers[i] + " >/dev/null 2>&1 && exec "
        + browsers[i] + " --refresh-platform-policy --no-startup-window >/dev/null 2>&1"])
    }
  }

  // --- notifications ----------------------------------------------------

  function applyNotifications(profile) {
    if (Model.usesGlobalDnd(profile)) {
      // Remember what DND was before taking it over, but only once per
      // session — re-asserting on reconcile must not record our own "on".
      if (!root.savedDnd) {
        dndProbe.running = true
      } else {
        root.setDnd("on")
      }
      watcher.running = false
    } else {
      root.restoreDnd()
      var wanted = Model.needsWatcher(profile)
      if (!wanted) root.sweepWatchers()
      watcher.running = wanted
    }
  }

  function clearNotifications() {
    watcher.running = false
    root.sweepWatchers()
    root.restoreDnd()
  }

  // Stopping our own Process only reaches the watcher this shell started. If
  // the previous shell was killed outright, its watcher is still on the bus
  // with no parent — this is what stops it outliving the session that began it.
  function sweepWatchers() {
    Quickshell.execDetached([root.watchScript, "--sweep"])
  }

  function restoreDnd() {
    if (!root.savedDnd) return
    var previous = root.savedDnd
    root.savedDnd = ""
    root.setDnd(previous)
  }

  function setDnd(value) {
    // setDnd is idempotent; toggleDnd would race against the current value.
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "setDnd", String(value)])
  }

  Process {
    id: dndProbe
    environment: root.procEnv
    command: ["omarchy-shell", "notifications", "dndState"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var was = text.trim()
        root.savedDnd = (was === "on" || was === "off") ? was : "off"
        root.saveState()
        root.setDnd("on")
      }
    }
  }

  Process {
    id: watcher
    environment: root.procEnv
    command: [root.watchScript]
    stdout: SplitParser {
      onRead: function (line) { root.onNotification(line) }
    }
    onExited: function (exitCode) {
      // Only a crash is worth reporting: stopping the watcher on purpose
      // sets running = false and exits non-zero from the signal.
      if (exitCode !== 0 && root.active && Model.needsWatcher(root.activeProfile))
        console.warn("oma-focus: notification watcher exited unexpectedly (" + exitCode + ")")
    }
  }

  function onNotification(line) {
    if (!root.active) return
    var n = Model.parseNotifyLine(line)
    if (!n) return
    if (!Model.shouldSilence(root.activeProfile, n.appName)) return
    // Dismissal is by summary; with nothing to match on there is no safe way
    // to pick the right toast, so let it stand rather than dismiss a stranger.
    if (!n.summary) return
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "dismiss", n.summary])
  }

  // --- session control --------------------------------------------------

  Timer {
    id: tick
    interval: 1000
    repeat: true
    running: false
    onTriggered: {
      root.now = Date.now()
      if (Model.expired(root.endsAt, root.now)) root.deactivate()
    }
  }

  // minutes <= 0 means indefinite. Passing -1 asks for the profile's own
  // default, which is what a click on the bar icon wants.
  function activate(name, minutes) {
    var profile = Model.findProfile(root.profiles, name)
    if (!profile) {
      root.lastError = "No profile named '" + name + "'"
      root.failed(root.lastError)
      return false
    }
    var mins = Math.floor(Number(minutes))
    if (!isFinite(mins) || mins < 0) mins = profile.defaultMinutes
    if (mins > 1440) mins = 1440

    root.activeName = profile.name
    root.endsAt = mins > 0 ? Date.now() + mins * 60000 : 0
    root.totalMs = mins * 60000
    root.paused = false
    root.pausedRemaining = 0
    root.now = Date.now()
    root.saveState()

    root.applyBlock(profile.domains)
    root.applyNotifications(profile)

    tick.running = root.endsAt > 0
    root.activated(profile.name)
    return true
  }

  function deactivate() {
    if (!root.activeName && !root.savedDnd) {
      // Still clear the block: reconcile calls this to mop up a stale one.
      root.applyBlock([])
      return true
    }
    tick.running = false
    root.activeName = ""
    root.endsAt = 0
    root.paused = false
    root.pausedRemaining = 0
    root.totalMs = 0
    root.applyBlock([])
    root.clearNotifications()
    root.saveState()
    root.deactivated()
    return true
  }

  function toggle(name, minutes) {
    if (root.active) return root.deactivate()
    var target = String(name || "") || root.lastProfileName()
    return root.activate(target, minutes === undefined ? -1 : minutes)
  }

  // What a bare click should start: the profile used last, else the first.
  property string preferredName: ""
  function lastProfileName() {
    if (root.preferredName && Model.findProfile(root.profiles, root.preferredName))
      return root.preferredName
    return root.profiles.length ? root.profiles[0].name : ""
  }
  onActivated: function (name) { root.preferredName = name }

  function extendBy(minutes) {
    if (!root.active) return false
    var mins = Math.floor(Number(minutes))
    if (!isFinite(mins) || mins <= 0) return false
    var cap = 1440 * 60000
    var before = root.remainingMs
    if (root.paused) {
      root.pausedRemaining = Math.min(root.pausedRemaining + mins * 60000, cap)
    } else {
      var base = root.endsAt > 0 ? root.endsAt : Date.now()
      root.endsAt = Math.min(base + mins * 60000, Date.now() + cap)
      tick.running = true
    }
    root.now = Date.now()
    root.totalMs = Math.min(root.totalMs + (root.remainingMs - before), cap)
    root.saveState()
    return true
  }

  // --- pause / resume ---------------------------------------------------

  function pause() {
    if (!root.running) return false
    root.now = Date.now()
    root.pausedRemaining = root.endsAt > 0 ? Math.max(0, root.endsAt - root.now) : 0
    root.endsAt = 0
    root.paused = true
    tick.running = false
    root.applyBlock([])
    root.clearNotifications()
    root.saveState()
    return true
  }

  function resume() {
    if (!root.active || !root.paused) return false
    root.now = Date.now()
    root.endsAt = root.pausedRemaining > 0 ? root.now + root.pausedRemaining : 0
    root.paused = false
    root.pausedRemaining = 0
    root.applyBlock(root.activeProfile.domains)
    root.applyNotifications(root.activeProfile)
    tick.running = root.endsAt > 0
    root.saveState()
    return true
  }

  function togglePause() {
    return root.paused ? root.resume() : root.pause()
  }

  // Moves the time left by `minutes` (negative skips ahead), on a timed
  // session only. Never past the session's full length; skipping through the
  // end finishes the session the way the deadline would have.
  function nudge(minutes) {
    if (!root.timed) return false
    // A session saved before totalMs existed has none; treat its time left as
    // the ceiling rather than letting a zero cap end it.
    var cap = root.totalMs > 0 ? root.totalMs : root.remainingMs
    var next = Math.min(root.remainingMs + minutes * 60000, cap)
    if (next <= 0) return root.deactivate()
    root.now = Date.now()
    if (root.paused) root.pausedRemaining = next
    else root.endsAt = root.now + next
    root.saveState()
    return true
  }

  function forward() { return root.nudge(-5) }
  function rewind() { return root.nudge(5) }

  // --- profile editing --------------------------------------------------
  //
  // Every mutation replaces the profiles array rather than editing in place,
  // so QML bindings in the panel actually fire.

  function withProfiles(name, mutate) {
    var idx = Model.profileIndex(root.profiles, name)
    if (idx === -1) return false
    var next = []
    for (var i = 0; i < root.profiles.length; i++)
      next.push(i === idx ? mutate(Model.sanitizeProfile(root.profiles[i])) : root.profiles[i])
    root.profiles = Model.sanitizeProfiles(next)
    root.saveProfiles()
    // An edit to the running profile must reach the machine immediately,
    // otherwise the panel and /etc/hosts disagree until the next toggle.
    // A paused session has nothing applied, so there is nothing to update.
    if (root.running && Model.profileIndex(root.profiles, root.activeName) === idx) {
      root.applyBlock(root.activeProfile.domains)
      root.applyNotifications(root.activeProfile)
    }
    return true
  }

  function addDomain(profileName, domain) {
    var d = Model.normalizeDomain(domain)
    if (!d) {
      root.lastError = "'" + String(domain).trim() + "' is not a valid site"
      root.failed(root.lastError)
      return false
    }
    root.lastError = ""
    return root.withProfiles(profileName, function (p) {
      if (p.domains.indexOf(d) === -1) p.domains = Model.normalizeDomains(p.domains.concat([d]))
      return p
    })
  }

  function removeDomain(profileName, domain) {
    var d = Model.normalizeDomain(domain)
    return root.withProfiles(profileName, function (p) {
      var next = []
      for (var i = 0; i < p.domains.length; i++)
        if (p.domains[i] !== d) next.push(p.domains[i])
      p.domains = next
      return p
    })
  }

  function setNotifyMode(profileName, mode) {
    return root.withProfiles(profileName, function (p) {
      p.notify = mode
      return p
    })
  }

  function addApp(profileName, app) {
    var a = String(app || "").trim()
    if (!a) return false
    return root.withProfiles(profileName, function (p) {
      if (p.apps.indexOf(a) === -1) p.apps = p.apps.concat([a])
      return p
    })
  }

  function removeApp(profileName, app) {
    var a = String(app || "").trim()
    return root.withProfiles(profileName, function (p) {
      var next = []
      for (var i = 0; i < p.apps.length; i++)
        if (p.apps[i] !== a) next.push(p.apps[i])
      p.apps = next
      return p
    })
  }

  function setDefaultMinutes(profileName, minutes) {
    return root.withProfiles(profileName, function (p) {
      p.defaultMinutes = minutes
      return p
    })
  }

  // --- IPC --------------------------------------------------------------
  //
  // Registered here, not in BarWidget.qml, because the widget exists once per
  // monitor and would register this target once per display. Panel visibility
  // does not need a handler: `omarchy-shell shell summon|hide|toggle <id>`
  // routes through Bar.findPanelWidget to the widget's own open/close.

  IpcHandler {
    target: "io.github.rektyrowdyy.focus"

    function on(profile: string, minutes: string): string {
      var name = String(profile || "") || root.lastProfileName()
      var mins = minutes === "" || minutes === undefined ? -1 : Number(minutes)
      return root.activate(name, mins) ? root.statusLine : ("error: " + root.lastError)
    }

    function off(): string {
      root.deactivate()
      return root.statusLine
    }

    function toggle(): string {
      root.toggle("", -1)
      return root.statusLine
    }

    function extend(minutes: string): string {
      return root.extendBy(Number(minutes)) ? root.statusLine : "error: not running, or bad duration"
    }

    function status(): string {
      return JSON.stringify({
        active: root.active,
        paused: root.paused,
        profile: root.activeName,
        endsAt: root.endsAt,
        remaining: root.countdown,
        notify: root.active ? root.activeProfile.notify : "",
        domains: root.active ? root.activeProfile.domains : [],
        setupDone: root.setupDone,
        error: root.lastError
      })
    }

    function profiles(): string {
      var names = []
      for (var i = 0; i < root.profiles.length; i++) names.push(root.profiles[i].name)
      return names.join("\n")
    }
  }

  Component.onCompleted: ensureDirs.running = true
}
