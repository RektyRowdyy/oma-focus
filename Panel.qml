import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Popup for the Focus bar widget: the running session at the top, then the
// profile list, then the selected profile's sites and notification rule.
//
// Layout and keyboard navigation only. Every fact shown and every change made
// belongs to the service singleton (`svc`), which BarWidget.qml injects — one
// service for the machine, however many monitors are showing this panel.
Panel {
  id: root
  moduleName: "io.github.rektyrowdyy.focus"
  ipcTarget: "io.github.rektyrowdyy.focus"
  // The service owns the single IpcHandler on this target. A second one here
  // would collide, and would be registered once per monitor besides.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var svc: root.service
  readonly property bool focusOn: svc ? svc.active === true : false
  readonly property bool paused: svc ? svc.paused === true : false
  readonly property bool timed: svc ? svc.timed === true : false
  readonly property var profiles: svc ? svc.profiles : []
  readonly property string countdown: svc ? svc.countdown : ""
  readonly property string lastError: svc ? svc.lastError : ""
  readonly property bool setupDone: svc ? svc.setupDone !== false : true

  // Which profile the panel is showing. Follows the running session, but can
  // be moved independently so a different profile can be edited or started
  // without ending the current one.
  property string viewName: ""
  readonly property var viewProfile: Model.findProfile(root.profiles, root.viewName)
      || (root.profiles.length ? root.profiles[0] : null)
  readonly property bool viewIsActive: root.focusOn && !!root.viewProfile
      && root.viewProfile.name === (svc.activeProfile ? svc.activeProfile.name : "")

  property int pendingMinutes: -1
  readonly property int chosenMinutes: root.pendingMinutes >= 0
    ? root.pendingMinutes : (root.viewProfile ? root.viewProfile.defaultMinutes : 0)

  function syncView() {
    if (!root.svc) return
    var preferred = root.focusOn && root.svc.activeProfile
      ? root.svc.activeProfile.name : root.svc.lastProfileName()
    if (preferred) root.viewName = preferred
  }

  onServiceChanged: syncView()

  Connections {
    target: root.svc
    enabled: !!root.svc
    function onActivated(name) { root.viewName = name; root.pendingMinutes = -1 }
    function onDeactivated() { root.pendingMinutes = -1 }
  }

  // --- panel lifecycle --------------------------------------------------

  function open() {
    root.syncView()
    root.cursorActive = false
    root.cursorIndex = 0
    root.controller.show()
  }

  function close() {
    domainField.focus = false
    domainField.text = ""
    root.controller.hide()
  }

  function toggle() { root.opened ? root.close() : root.open() }

  // The base Panel's switchPanel passes this Panel as the slot owner, but
  // Bar.qml matches slots against the BarWidget. For a Loader-hosted panel
  // those are different objects, so Tab silently does nothing without this.
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // --- keyboard navigation ----------------------------------------------
  //
  // One flat cursor over a computed row list, so Up/Down walks the whole panel
  // in the order it is read rather than trapping inside a section.

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property var navRows: {
    var rows = []
    for (var i = 0; i < root.profiles.length; i++)
      rows.push({ kind: "profile", index: i })
    rows.push({ kind: "primary", index: 0 })
    var domains = root.viewProfile ? root.viewProfile.domains : []
    for (var d = 0; d < domains.length; d++)
      rows.push({ kind: "domain", index: d })
    return rows
  }

  function rowAt(i) {
    return (i >= 0 && i < root.navRows.length) ? root.navRows[i] : null
  }

  function isCursor(kind, index) {
    if (!root.cursorActive) return false
    var r = root.rowAt(root.cursorIndex)
    return !!r && r.kind === kind && r.index === index
  }

  function setCursor(kind, index) {
    for (var i = 0; i < root.navRows.length; i++) {
      if (root.navRows[i].kind === kind && root.navRows[i].index === index) {
        root.cursorActive = true
        root.cursorIndex = i
        return
      }
    }
  }

  function moveCursor(dy) {
    var count = root.navRows.length
    if (count === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      return
    }
    root.cursorIndex = ((root.cursorIndex + dy) % count + count) % count
  }

  function activateCursor() {
    var r = root.rowAt(root.cursorIndex)
    if (!r) return
    if (r.kind === "profile") root.startProfile(root.profiles[r.index].name)
    else if (r.kind === "primary") root.primaryAction()
    else if (r.kind === "domain") root.showProfile(root.viewName)
  }

  function deleteCursor() {
    var r = root.rowAt(root.cursorIndex)
    if (!r || r.kind !== "domain" || !root.viewProfile) return
    root.svc.removeDomain(root.viewProfile.name, root.viewProfile.domains[r.index])
  }

  // --- actions ----------------------------------------------------------

  function showProfile(name) {
    root.viewName = name
    root.pendingMinutes = -1
  }

  function startProfile(name) {
    if (!root.svc) return
    // Clicking the running profile pauses or resumes it, as a left-click on
    // the bar icon does; clicking another one switches straight to it rather
    // than making the user stop first.
    if (root.focusOn && root.svc.activeProfile && root.svc.activeProfile.name === name) {
      root.svc.togglePause()
      return
    }
    root.svc.activate(name, root.pendingMinutes)
  }

  function primaryAction() {
    if (!root.svc || !root.viewProfile) return
    if (root.viewIsActive) root.svc.deactivate()
    else root.svc.activate(root.viewProfile.name, root.pendingMinutes)
  }

  function submitDomain() {
    if (!root.svc || !root.viewProfile) return
    var text = domainField.text
    if (!text.trim()) return
    if (root.svc.addDomain(root.viewProfile.name, text)) domainField.text = ""
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The add-site field takes single characters, arrows and Return; with
      // the navigator live those would be swallowed before the field sees them.
      blocked: domainField.activeFocus
      onMoveRequested: function (dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // --- hero ---------------------------------------------------------

        PanelHero {
          width: parent.width
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: root.focusOn && root.svc.activeProfile
            ? ((root.paused ? "Focus paused: " : "Focus: ") + root.svc.activeProfile.name)
            : "Focus off"

          // `meta` is the uppercase caption under the title. While focus is off
          // it describes the profile being viewed, so the numbers underneath it
          // are never mistaken for a description of the off state.
          meta: {
            if (root.focusOn && root.svc.activeProfile) {
              var running = Model.profileSummary(root.svc.activeProfile)
              return root.countdown ? running : (running + " \u00b7 no time limit")
            }
            if (!root.viewProfile) return ""
            return root.viewProfile.name + " \u00b7 " + Model.profileSummary(root.viewProfile)
          }

          iconComponent: Component {
            Text {
              text: "󱅻"  // nf-md-meditation, same glyph as the bar
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.focusOn ? 1.0 : 0.45
            }
          }

          // The time left sits here beside the toggle rather than in the hero's
          // `detail`, which PanelHero places in the title row: that aligns the
          // pill with the title alone, leaving it off-center against the toggle.
          // Hidden on an untimed session rather than showing an empty badge.
          trailingControl: Component {
            Row {
              spacing: Style.space(10)

              BorderSurface {
                visible: root.focusOn && root.countdown !== ""
                implicitWidth: countdownText.implicitWidth + Style.space(10)
                implicitHeight: countdownText.implicitHeight + Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                color: "transparent"
                borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
                radius: Style.cornerRadius

                Text {
                  id: countdownText
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.countdown
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              ToggleSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: root.focusOn
                busy: root.svc ? root.svc.busy === true : false
                foreground: root.foreground
                hasCursor: root.isCursor("primary", 0)
                onHovered: function (on) { if (on) root.setCursor("primary", 0) }
                onToggled: {
                  if (root.focusOn) root.svc.deactivate()
                  else root.primaryAction()
                }
              }
            }
          }
        }

        // Transport for the running session. Rewind and forward move the time
        // left by five minutes, so an untimed session only gets play/pause.
        Row {
          visible: root.focusOn
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(16)

          PanelActionButton {
            visible: root.timed
            enabled: root.svc ? root.svc.remainingMs < root.svc.totalMs : false
            opacity: enabled ? 1.0 : 0.35
            iconText: "󱇹"  // nf-md-rewind_5
            tooltipText: "Add 5 minutes back"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.svc.rewind()
          }

          PanelActionButton {
            iconText: root.paused ? "󰐊" : "󰏤"  // nf-md-play / nf-md-pause
            tooltipText: root.paused ? "Resume" : "Pause"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.svc.togglePause()
          }

          PanelActionButton {
            visible: root.timed
            iconText: "󱇸"  // nf-md-fast_forward_5
            tooltipText: "Skip 5 minutes"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.svc.forward()
          }
        }

        // Setup and validation problems both surface here, above everything
        // else: a block that silently did nothing is the worst outcome.
        BorderSurface {
          width: parent.width
          visible: !root.setupDone || root.lastError !== ""
          implicitHeight: noticeText.implicitHeight + Style.space(16)
          color: Style.hoverFillFor(Color.urgent, Color.urgent)
          borderSpec: Border.flat(Color.urgent, 1)

          Text {
            id: noticeText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            text: root.setupDone
              ? root.lastError
              : "Site blocking needs one-time setup:\nrun scripts/setup.sh from the plugin folder."
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        PanelSeparator { foreground: root.foreground }

        // --- profiles -----------------------------------------------------

        PanelSectionHeader {
          text: "PROFILES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(3)

          Repeater {
            model: root.profiles

            ProfileRow {
              width: column.width
              rowIndex: index
              profileName: modelData.name
              summary: Model.profileSummary(modelData)
            }
          }
        }

        // --- duration -----------------------------------------------------

        PanelSectionHeader {
          text: "FOR"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        ButtonGroup {
          width: parent.width
          foreground: root.foreground
          fontFamily: root.fontFamily
          options: [
            { value: "25", label: "25m" },
            { value: "50", label: "50m" },
            { value: "60", label: "1h" },
            { value: "0", label: "∞" }
          ]
          value: String(root.chosenMinutes)
          onChanged: function (v) {
            root.pendingMinutes = Number(v)
            // Changing the duration mid-session should mean what it says,
            // rather than waiting for the next time focus is started.
            if (root.viewIsActive) {
              root.svc.activate(root.viewProfile.name, root.pendingMinutes)
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // --- blocked sites ------------------------------------------------

        PanelSectionHeader {
          text: "BLOCKED SITES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        TextField {
          id: domainField
          width: parent.width
          foreground: root.foreground
          font.family: root.fontFamily
          placeholderText: "Add a site, e.g. instagram.com"
          onAccepted: root.submitDomain()
        }

        Column {
          width: parent.width
          spacing: Style.space(3)
          visible: !!root.viewProfile && root.viewProfile.domains.length > 0

          Repeater {
            model: root.viewProfile ? root.viewProfile.domains : []

            DomainRow {
              width: column.width
              rowIndex: index
              domain: modelData
            }
          }
        }

        Text {
          visible: !!root.viewProfile && root.viewProfile.domains.length === 0
          width: parent.width
          text: "No sites blocked in this profile."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.foreground }

        // --- notifications ------------------------------------------------

        PanelSectionHeader {
          text: "NOTIFICATIONS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Dropdown {
          width: parent.width
          showLabel: false
          foreground: root.foreground
          fontFamily: root.fontFamily
          options: [
            { value: "off", label: "Leave notifications alone" },
            { value: "all", label: "Silence everything" },
            { value: "allow", label: "Silence all but chosen apps" },
            { value: "block", label: "Silence only chosen apps" }
          ]
          value: root.viewProfile ? root.viewProfile.notify : "off"
          onChanged: function (v) {
            if (root.viewProfile) root.svc.setNotifyMode(root.viewProfile.name, v)
          }
        }

        Text {
          width: parent.width
          visible: !!root.viewProfile && root.viewProfile.notify !== "off"
          text: {
            if (!root.viewProfile) return ""
            var mode = root.viewProfile.notify
            if (mode === "all") return "Turns on Do Not Disturb while focused. Nothing appears at all."
            var names = root.viewProfile.apps.length
              ? root.viewProfile.apps.join(", ") : "(none chosen yet)"
            return (mode === "allow" ? "Allowed: " : "Silenced: ") + names
              + "\nSilenced notifications flash briefly before they are dismissed."
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // Plain properties, never `required`: marking them required on an inline
  // component that a Repeater builds through explicit delegate bindings
  // silently breaks construction.
  component ProfileRow: CursorSurface {
    id: prow
    property int rowIndex: 0
    property string profileName: ""
    property string summary: ""

    readonly property bool isRunning: root.focusOn && root.svc.activeProfile
      && root.svc.activeProfile.name === prow.profileName
    readonly property bool isViewed: !!root.viewProfile && root.viewProfile.name === prow.profileName

    hasCursor: root.isCursor("profile", prow.rowIndex)
    current: prow.isViewed
    foreground: root.foreground
    implicitHeight: prowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor("profile", prow.rowIndex)
      // A click selects the profile to look at; the switch or Enter starts it.
      // Starting focus is not something a stray click should be able to do.
      onClicked: root.showProfile(prow.profileName)
      onDoubleClicked: root.startProfile(prow.profileName)
    }

    Item {
      id: prowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(prowLabels.implicitHeight, prowMark.implicitHeight)

      Text {
        id: prowMark
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: prow.isRunning ? "●" : "○"
        color: prow.isRunning && !root.paused ? Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Column {
        id: prowLabels
        anchors.left: prowMark.right
        anchors.right: parent.right
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: prow.profileName
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: prow.isViewed
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: prow.summary
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component DomainRow: CursorSurface {
    id: drow
    property int rowIndex: 0
    property string domain: ""

    hasCursor: root.isCursor("domain", drow.rowIndex)
    foreground: root.foreground
    implicitHeight: drowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onContainsMouseChanged: if (containsMouse) root.setCursor("domain", drow.rowIndex)
    }

    Item {
      id: drowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      implicitHeight: Math.max(drowText.implicitHeight, removeButton.implicitHeight)

      Text {
        id: drowText
        anchors.left: parent.left
        anchors.right: removeButton.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: drow.domain
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      PanelActionButton {
        id: removeButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "×"
        tooltipText: "Stop blocking " + drow.domain
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: if (root.viewProfile) root.svc.removeDomain(root.viewProfile.name, drow.domain)
      }
    }
  }
}
