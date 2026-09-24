import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon for Focus: a Nerd Font glyph, dimmed while focus is off, with the
// remaining time beside it during a timed session.
//
// This file is a view. The bar builds one of these per monitor, so it owns no
// state and performs no side effects — everything goes through the service
// singleton reached below. The Loader/injectPanel wiring follows the same
// shape as io.github.rektyrowdyy.whatsapp's BarWidget, since the bar host only
// treats a module as summonable when open()/close()/opened are exposed here on
// the top-level widget rather than on the panel behind the Loader.
BarWidget {
  id: root
  moduleName: "io.github.rektyrowdyy.focus"

  // The shell hands a plugin its own service and no one else's.
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(root.moduleName) : null

  readonly property bool focusOn: service ? service.active === true : false
  readonly property string countdown: service ? service.countdown : ""
  readonly property string profileName: service && service.activeProfile ? service.activeProfile.name : ""
  readonly property bool busy: service ? service.busy === true : false

  function settingBool(key, fallback) {
    var v = root.setting(key, fallback)
    return v === true || v === "true"
  }
  readonly property bool showCountdown: root.settingBool("showCountdown", true)

  // nf-md-meditation (U+F117B). Verified present in the JetBrainsMono Nerd
  // Font this bar resolves `monospace` to.
  readonly property string glyph: "󱅻"

  // A vertical bar has no room for a number beside the icon, and an untimed
  // session has no number to show; both fall back to the accent dot.
  readonly property bool showLabel: !root.vertical && root.focusOn
    && root.showCountdown && root.countdown !== ""

  readonly property string tooltipText: {
    if (!root.service) return "Focus"
    if (!root.focusOn) return "Focus off — click to start " + root.service.lastProfileName()
    var t = "Focus: " + root.profileName
    if (root.countdown) t += " · " + root.countdown + " left"
    var p = root.service.activeProfile
    if (p) t += "\n" + Model.profileSummary(p)
    return t + "\nRight-click for profiles"
  }

  readonly property color activeIconColor: bar ? bar.barForeground : Color.foreground
  readonly property color dimIconColor: Qt.darker(activeIconColor, 1.6)

  // --- panel shape contract for shell.summon/hide/toggle routing ---------

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  function open() { if (panelLoader.item && panelLoader.item.open) panelLoader.item.open() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  // Left-click is the whole point of the plugin: start or end focus without
  // opening anything. Right-click is for choosing which profile.
  function quickToggle() {
    if (!root.service) return
    root.service.toggle("", -1)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    visible: false
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // One glyph for both states, dimmed when focus is off, rather than swapping
  // shapes: the bar should read as "this is the focus control" at a glance,
  // with brightness (plus the countdown, or the dot) carrying the state.
  //
  // WidgetButton rather than BarIconButton because the latter pins itself to a
  // square icon slot with labelVisible hard-coded false, leaving nowhere for
  // the countdown to sit.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fontSize: Style.bar.iconFont
    active: root.opened
    tooltipText: root.tooltipText
    fixedWidth: root.vertical ? -1 : Math.max(Style.bar.iconSlot, content.implicitWidth + Style.spaceReal(7) * 2)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1

    readonly property color glyphColor: button.active
      ? button.activeColor
      : (root.focusOn ? button.foreground : root.dimIconColor)

    Row {
      id: content
      anchors.centerIn: parent
      spacing: root.showLabel ? Style.space(5) : 0

      Item {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        anchors.verticalCenter: parent.verticalCenter

        OpticalGlyph {
          id: focusGlyph
          anchors.fill: parent
          text: root.glyph
          color: button.glyphColor
          fontFamily: button.fontFamily
          fontSize: button.fontSize
          opacity: root.busy ? 0.45 : 1.0

          Behavior on opacity {
            NumberAnimation { duration: 120 }
          }
        }

        // A small accent dot for anyone running with the countdown switched
        // off, or on an untimed session where there is no number to show.
        BorderSurface {
          visible: root.focusOn && !root.showLabel
          width: Math.max(6, Style.bar.iconCanvas * 0.3)
          height: width
          radius: width / 2
          color: Color.accent
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.rightMargin: -Style.space(1)
          anchors.bottomMargin: -Style.space(1)
          borderSpec: Border.flat(Color.bar.background, 1)
        }
      }

      Text {
        visible: root.showLabel
        anchors.verticalCenter: parent.verticalCenter
        text: root.countdown
        textFormat: Text.PlainText
        color: button.glyphColor
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
        renderType: Text.NativeRendering
      }
    }

    onPressed: function (b) {
      if (b === Qt.LeftButton) root.quickToggle()
      else root.togglePanel()
    }
  }
}
