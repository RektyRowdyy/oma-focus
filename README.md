# Focus

Apple-style Focus mode for the [Omarchy](https://omarchy.org) shell.

One click blocks the websites you lose time to and silences the notifications
you don't want, for as long as you say — then puts everything back.

![Focus panel](preview.png)

- **Named profiles.** Work, Personal, Sleep, or your own. Each has its own site
  list and its own notification rule. One runs at a time.
- **Site blocking** that covers real browsers, not just one. Blocked hosts go
  into `/etc/hosts` (which reaches Zen, Firefox, and anything that isn't a
  browser at all) *and* into Chromium's managed-policy directory (which is
  immune to DNS-over-HTTPS and shows a proper "blocked by your administrator"
  page instead of a confusing connection error).
- **Notification rules per profile:** leave them alone, silence everything,
  silence all *but* a chosen few, or silence only a chosen few.
- **Timers.** Run for 25m / 50m / 1h, or with no limit. The bar counts down and
  focus ends itself.
- **Pause for a break.** Pausing lifts the block and the silencing and holds the
  clock; resuming puts both back and carries on where it stopped. Skip ahead or
  give yourself back five minutes at a time.
- **It always lets go.** If the shell crashes or the machine reboots mid-session,
  the block is cleared the moment the shell comes back.

## Install

```bash
omarchy plugin add https://github.com/RektyRowdyy/oma-focus.git --enable
```

Then, once, to let focus toggle without a password prompt every time:

```bash
cd ~/.config/omarchy/plugins/io.github.rektyrowdyy.focus
./scripts/setup.sh
```

This asks for your password once. See [Privilege boundary](#privilege-boundary)
for exactly what it installs and what that lets through — read it before you run
it. Until you do, everything except site blocking works, and the panel says so.

**Requires** `dbus-monitor` (from the `dbus` package, already present on
Omarchy) and `jq`. Both are used only as described below.

## Usage

| Action | What it does |
|---|---|
| Left-click the bar icon | Start focus with the profile you used last, or pause / resume a running session |
| Middle-click the bar icon | End focus |
| Right-click the bar icon | Open the panel |
| Rewind 5 / Play-pause / Forward 5 in the panel | Add 5 minutes back (never past the session's full length), pause or resume, skip 5 minutes ahead |
| `↑` `↓` in the panel | Move between profiles and blocked sites |
| `Enter` | Start the profile under the cursor (or pause / resume it, if it's running) |
| `x` | Stop blocking the site under the cursor |
| `Esc` | Close |

While focus runs, the bar shows the time left. An untimed session shows a dot
instead. A paused session keeps its time on show, dimmed, and stays paused
across a shell restart. Rewind and forward apply only to timed sessions;
skipping forward past the end finishes the session. The switch in the panel
ends focus outright.

From a script or a keybinding:

```bash
omarchy-shell io.github.rektyrowdyy.focus on Work 50   # profile, minutes (0 = no limit)
omarchy-shell io.github.rektyrowdyy.focus on Work ""   # the profile's own default duration
omarchy-shell io.github.rektyrowdyy.focus extend 15
omarchy-shell io.github.rektyrowdyy.focus off
omarchy-shell io.github.rektyrowdyy.focus toggle
omarchy-shell io.github.rektyrowdyy.focus status       # JSON
omarchy-shell io.github.rektyrowdyy.focus profiles
omarchy-shell shell toggle io.github.rektyrowdyy.focus '{}'   # the panel
```

Both arguments to `on` are required — pass `""` for minutes to use the profile's
default. That is a constraint of the shell's IPC, not a preference.

To bind focus to a key, add to `~/.config/hypr/bindings.conf`:

```
bindd = SUPER SHIFT, F, Toggle focus mode, exec, omarchy-shell io.github.rektyrowdyy.focus toggle
```

## Configure

Sites and notification rules are editable in the panel. Profiles themselves live
in `~/.config/omarchy/oma-focus/profiles.json`, written on first run:

```json
{
  "profiles": [
    {
      "name": "Work",
      "domains": ["instagram.com", "x.com"],
      "notify": "allow",
      "apps": ["Google Calendar", "Slack"],
      "defaultMinutes": 50
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | Shown in the panel; also how `focus on <name>` addresses it. Must be unique (case-insensitively) |
| `domains` | Hosts to block. `www.` and subdomains are covered automatically |
| `notify` | `off`, `all`, `allow`, or `block` — see below |
| `apps` | App names for `allow` / `block`. Matched case-insensitively, as a substring either way, so `slack` catches `Slack` |
| `defaultMinutes` | Duration a bare click uses. `0` means no limit |

Edit it while the shell is running and reload with `omarchy-restart-shell`.

### Notification rules

| `notify` | Behaviour |
|---|---|
| `off` | Notifications are untouched |
| `all` | Do Not Disturb is turned on. Nothing appears at all, and nothing flashes |
| `allow` | Everything is silenced **except** `apps` |
| `block` | Only `apps` are silenced |

`allow` and `block` are best-effort and have a visible cost — see
[Known limits](#known-limits).

The Do Not Disturb setting you had before focus started is restored when it ends,
so if you keep DND on permanently, focus won't quietly turn it off for you.

### Bar widget settings

`showCountdown` (default on) — show the remaining time next to the icon. With it
off, a running session is marked with a dot instead.

## Remove

```bash
cd ~/.config/omarchy/plugins/io.github.rektyrowdyy.focus
./scripts/setup.sh --remove
omarchy plugin remove io.github.rektyrowdyy.focus
```

`--remove` clears any block still in place, then deletes
`/usr/local/bin/oma-focus-block` and `/etc/sudoers.d/oma-focus`. Nothing of
either is left behind, and `/etc/hosts` goes back to exactly what it was.

Your profiles stay at `~/.config/omarchy/oma-focus/` in case you reinstall;
delete that directory and `~/.local/state/omarchy/oma-focus/` to remove them too.

## Privilege boundary

**Omarchy plugins are not sandboxed.** This one runs inside the long-lived
`omarchy-shell` process with your full permissions, as every plugin does. What
follows is what it actually does with them.

**It runs two programs of its own**, both shipped in `bin/` and readable:

- `oma-focus-block` — the only part that needs root. It rewrites a marked block
  in `/etc/hosts` and writes `oma-focus.json` into the Chromium and Chrome
  managed-policy directories. Every path and every IP address it writes is
  hard-coded. Each domain is checked against
  `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$` *before*
  it escalates, so nothing that isn't a bare hostname ever reaches a root-owned
  write. It never creates a policy directory a browser doesn't already have, and
  never follows a symlink into one. Content outside its `# >>> oma-focus >>>`
  markers is copied through untouched.
- `oma-focus-notifywatch` — runs `dbus-monitor` on your **session** bus, filtered
  to `Notify` method calls, and prints the app name and summary of each one. It
  runs only while a profile with `allow` or `block` rules is active. While it
  runs it can see the app name, summary and body of every notification you
  receive. It parses only the app name and summary, stores nothing, and sends
  nothing anywhere.

**What `scripts/setup.sh` installs**, and what that means:

1. `/usr/local/bin/oma-focus-block`, owned by root and not writable by you. It
   has to live outside the plugin directory: a passwordless rule pointing at a
   file you can edit would be a one-line path to root.
2. `/etc/sudoers.d/oma-focus`, containing exactly
   `<you> ALL=(root) NOPASSWD: /usr/local/bin/oma-focus-block`, validated with
   `visudo -c` before it is installed.

   **This is a real grant and worth understanding.** After it, any process
   running as you can invoke that one program without a password. The worst it
   can do is point hostnames of its choosing at `127.0.0.1` — a local denial of
   service against your own browsing. It cannot redirect a hostname anywhere
   else, write any other file, or run any other command, because the helper
   hard-codes all three. If that trade isn't one you want, skip `setup.sh`: the
   plugin then asks for a password through polkit on each toggle instead.

**It also calls** `omarchy-shell notifications setDnd|dismiss` to drive whichever
notification daemon your shell is running, and `chromium --refresh-platform-policy`
so a block applies to already-open windows. It does not replace your notification
daemon and does not take over the notification bus.

**Nothing is sent off the machine.** There is no network access of any kind.

## Known limits

- **Silenced notifications flash before they disappear.** For `allow` and `block`,
  the notification is visible for roughly 50–150 ms first. This is not a bug that
  can be fixed from a plugin: the shell owns `org.freedesktop.Notifications` and
  only one process can, so Focus cannot intercept a notification before it is
  shown — it can only dismiss it immediately afterwards. `notify: "all"` uses Do
  Not Disturb instead and has no flash.
- **Dismissal matches on the summary text.** If a silenced app and an allowed app
  show notifications with the same title at the same moment, both may be
  dismissed. A notification with an empty summary is left alone.
- **Zen and Firefox are covered by `/etc/hosts` but not by browser policy.** Their
  `policies.json` is read only at startup and lives in a package-owned directory,
  so Focus does not touch it.
- **A browser with DNS-over-HTTPS switched on manually will bypass `/etc/hosts`.**
  Chromium and Chrome are still covered, because managed policy doesn't care
  about DNS. Zen and Firefox would not be.
- **Blocking is a speed bump, not a lock.** Anything you can run as yourself can
  undo it. It is built to interrupt a habit, not to resist you.

## Development

```bash
./scripts/dev-install.sh    # copy into ~/.config/omarchy/plugins (never a symlink)
omarchy-restart-shell       # required: a rescan leaves old QML running
node tests/model.test.mjs   # pure-logic tests, no shell needed
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" *.qml 2>&1 | grep '^Error'
```

`qmllint` emits many `qs.Commons` / `qs.Ui` unresolved-type warnings under that
invocation; first-party Omarchy widgets emit the same ones. Judge by errors.

## License

MIT — see [LICENSE](LICENSE).
