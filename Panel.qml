import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar pill and the day panel behind it. The pill is not a launcher for
// the timer, it *is* the timer: it carries the project, the elapsed time,
// and a fill that creeps across as the current hour runs out, so the common
// case — "what am I on and how long" — costs a glance and no clicks.
Panel {
  id: root
  moduleName: "pb.punch"

  // The clock lives in the service singleton; every bar instance, on every
  // monitor, is a view onto the same object.
  readonly property var punch: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("pb.punch") : null
  property var registeredService: null

  // Read the running entry through one property and test *that* everywhere.
  // Deriving a boolean first and dereferencing later leaves a window where
  // the boolean is still true and the entry is already gone.
  readonly property var live: punch && punch.running ? punch.running : null
  readonly property bool tracking: live !== null
  readonly property string projectName: live ? String(live.project) : ""
  readonly property int elapsed: punch ? punch.elapsed : 0
  readonly property real hourFill: tracking ? Model.hourFraction(elapsed) : 0

  // Ui/Panel is the popup base, not the widget base, so the bar geometry
  // every layout branch reads has to come off the host directly.
  readonly property bool vertical: bar ? bar.vertical === true : false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string idleGlyph: "󰥔"
  readonly property string runGlyph: "󰑊"

  function projectColor(name) {
    if (!name) return foreground
    return Qt.hsla(Model.projectHue(name), 0.52, 0.62, 1.0)
  }

  readonly property color activeColor: tracking ? projectColor(projectName) : dim
  readonly property color barActiveColor: tracking ? projectColor(projectName) : Qt.darker(barForeground, 1.6)

  readonly property bool showProjectName: punch ? punch.setting("showProjectName", true) === true : true
  readonly property bool hideWhenStopped: punch ? punch.setting("hideWhenStopped", false) === true : false

  // Nothing running means nothing to say. The pill is a quiet glyph until
  // there is a clock to report, and only then earns the space to report it.
  readonly property string pillLabel: {
    if (root.vertical) return ""
    if (!tracking) return idleGlyph
    var parts = [runGlyph]
    if (showProjectName && projectName) parts.push(projectName)
    parts.push(Model.clockDuration(elapsed))
    return parts.join(" ")
  }

  // ------------------------------------------------------------- panel state

  property int cursor: 0
  property bool cursorActive: false

  readonly property var dayEntries: punch ? punch.todayEntries : []
  readonly property var liveEntry: live && punch
    ? Model.clipToRange({ id: "running", project: live.project, note: live.note, start: live.start, end: punch.nowSec },
        punch.todayStart, Model.dayEnd(punch.todayStart))
    : null
  // The running stretch sits in the list like any other row so the day reads
  // as one continuous story, but it is not editable — stop it first.
  readonly property var rows: liveEntry ? dayEntries.concat([liveEntry]) : dayEntries
  readonly property var totals: Model.byProject(rows)
  readonly property var stripWindow: punch ? Model.dayWindow(rows, punch.todayStart, punch.nowSec) : ({ from: 0, to: 1 })

  function clampCursor() {
    if (rows.length === 0) { cursor = 0; return }
    cursor = Math.max(0, Math.min(rows.length - 1, cursor))
  }

  function selectedRow() {
    if (!rows.length) return null
    return rows[Math.max(0, Math.min(rows.length - 1, cursor))]
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + dy))
  }

  // Enter on a row picks that project back up. Resuming what you were doing
  // an hour ago is the single most common thing to want from a day list.
  function activateCursor() {
    var row = selectedRow()
    if (!punch || !row) return
    if (row.id === "running") punch.stop()
    else punch.switchTo(row.project)
  }

  function deleteSelected() {
    var row = selectedRow()
    if (!punch || !row || row.id === "running") return
    punch.deleteEntry(row.id)
    clampCursor()
  }

  function adjustSelected(minutes) {
    var row = selectedRow()
    if (!punch || !row || row.id === "running") return
    punch.adjustEntry(row.id, minutes)
  }

  function toggleClock() {
    if (punch) punch.toggle()
  }

  function openQuickSwitch() {
    close()
    if (punch) punch.openQuickSwitch()
  }

  // ------------------------------------------------------------- wiring

  function syncRegistration() {
    if (registeredService === punch) return
    if (registeredService && typeof registeredService.unregisterWidget === "function")
      registeredService.unregisterWidget(root)
    registeredService = punch
    if (registeredService && typeof registeredService.registerWidget === "function")
      registeredService.registerWidget(root)
  }

  onPunchChanged: syncRegistration()
  Component.onCompleted: syncRegistration()
  Component.onDestruction: if (registeredService && typeof registeredService.unregisterWidget === "function")
    registeredService.unregisterWidget(root)

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = Math.max(0, rows.length - 1)
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  visible: !hideWhenStopped || tracking
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  // ------------------------------------------------------------- the pill

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pillLabel
    labelVisible: !root.vertical
    hasVisualContent: root.vertical || text !== ""
    fixedWidth: root.vertical ? -1 : (root.tracking ? -1 : Style.bar.iconSlot)
    horizontalMargin: root.tracking && !root.vertical ? 9 : 6
    foreground: root.tracking ? root.barActiveColor : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.5)
    tooltipText: root.tracking
      ? root.projectName + " · " + Model.humanDuration(root.elapsed) + " · right-click to stop"
      : "Not tracking · right-click to start " + (root.punch && root.punch.lastProject ? root.punch.lastProject : "a project")

    onPressed: function(code) {
      if (code === Qt.RightButton) root.toggleClock()
      else if (code === Qt.MiddleButton) root.openQuickSwitch()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (!root.punch) return
      var step = wheelAccumulator.accumulate(delta)
      if (step !== 0) root.punch.cycle(step > 0 ? -1 : 1)
    }

    // Behind the label while running: a tinted bed in the project's color,
    // with a fill that crosses it once per hour of tracked time.
    Rectangle {
      z: -1
      anchors.centerIn: parent
      width: root.vertical ? Style.bar.iconSlot - Style.space(4) : parent.width - Style.space(2)
      height: root.vertical ? Style.bar.iconSlot - Style.space(4) : Math.round(parent.height * 0.72)
      radius: Math.max(Style.cornerRadius, height / 2)
      visible: root.tracking
      color: Util.alpha(root.barActiveColor, 0.14)
      clip: true

      Rectangle {
        height: parent.height
        width: Math.round(parent.width * root.hourFill)
        radius: parent.radius
        color: Util.alpha(root.barActiveColor, 0.18)
        Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
      }
    }

    // Vertical bars have no room for a label, so the glyph carries it and
    // the tooltip carries the rest.
    Text {
      visible: root.vertical
      anchors.centerIn: parent
      text: root.tracking ? root.runGlyph : root.idleGlyph
      color: button.foreground
      font.family: button.fontFamily
      font.pixelSize: Style.bar.iconFont
    }
  }

  QtObject {
    id: wheelAccumulator
    property int remainder: 0
    function accumulate(delta) {
      var result = Util.wheelSteps(remainder, delta)
      remainder = result.remainder
      return result.steps
    }
  }

  // ------------------------------------------------------------- the panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onDeleteRequested: root.deleteSelected()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.toggleClock()
        else if (t === "p" || t === "P" || t === "n" || t === "N") root.openQuickSwitch()
        else if (t === "+" || t === "=") root.adjustSelected(5)
        else if (t === "-" || t === "_") root.adjustSelected(-5)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- hero: what is running, for how long, and where the day sits
          Item {
            width: parent.width
            implicitHeight: heroRow.implicitHeight

            RowLayout {
              id: heroRow
              width: parent.width
              spacing: Style.space(12)

              Text {
                text: root.tracking ? root.runGlyph : root.idleGlyph
                color: root.activeColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                Layout.alignment: Qt.AlignVCenter
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  Layout.fillWidth: true
                  text: root.tracking ? root.projectName : "Not tracking"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  text: root.tracking ? Model.preciseDuration(root.elapsed) : "—:—:—"
                  color: root.tracking ? root.activeColor : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                }

                Text {
                  Layout.fillWidth: true
                  visible: !!root.live && root.live.note !== ""
                  text: root.live ? root.live.note : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              ToggleSwitch {
                checked: root.tracking
                foreground: root.foreground
                Layout.alignment: Qt.AlignVCenter
                onToggled: root.toggleClock()
              }
            }
          }

          // ---- day strip
          Item {
            width: parent.width
            implicitHeight: Style.space(30)

            Rectangle {
              id: strip
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: Style.space(18)
              radius: Style.cornerRadius
              color: Util.alpha(root.foreground, 0.06)
              clip: true

              readonly property int windowFrom: root.stripWindow.from
              readonly property int windowSpan: Math.max(1, root.stripWindow.to - root.stripWindow.from)

              Repeater {
                model: root.rows
                Rectangle {
                  required property var modelData
                  x: Math.round(strip.width * (modelData.start - strip.windowFrom) / strip.windowSpan)
                  width: Math.max(Style.space(2), Math.round(strip.width * (modelData.end - modelData.start) / strip.windowSpan))
                  height: strip.height
                  radius: Style.cornerRadius
                  color: root.projectColor(modelData.project)
                  opacity: modelData.id === "running" ? 1.0 : 0.75
                }
              }
            }

            Text {
              anchors.left: parent.left
              anchors.top: strip.bottom
              anchors.topMargin: Style.space(3)
              text: Model.clockTime(root.stripWindow.from)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              anchors.top: strip.bottom
              anchors.topMargin: Style.space(3)
              text: Model.clockTime(root.stripWindow.to)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- day and week totals
          Row {
            width: parent.width
            spacing: Style.space(32)

            Total { label: "TODAY"; seconds: root.punch ? root.punch.todaySeconds : 0 }
            Total { label: "THIS WEEK"; seconds: root.punch ? root.punch.weekSeconds : 0 }
          }

          PanelSeparator { foreground: root.foreground }

          // ---- per-project totals for today
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.totals.length > 0

            PanelSectionHeader {
              text: "TODAY BY PROJECT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.totals
              ProjectTotal {
                required property var modelData
                width: parent.width
                project: modelData.project
                seconds: modelData.seconds
              }
            }
          }

          PanelSeparator { foreground: root.foreground; visible: root.totals.length > 0 }

          // ---- the day's entries
          Column {
            id: rowColumn
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "ENTRIES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.rows.length === 0
              width: parent.width
              text: "Nothing tracked today."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(8)
              bottomPadding: Style.space(8)
            }

            Repeater {
              model: root.rows
              EntryRow {
                required property var modelData
                required property int index
                width: rowColumn.width
                entry: modelData
                rowIndex: index
              }
            }
          }

          Text {
            width: parent.width
            text: "enter resume · s start/stop · p switch · +/- 5 min · x delete"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- components

  component Total: Column {
    id: totalBlock
    property string label: ""
    property int seconds: 0

    spacing: Style.space(1)

    Text {
      text: totalBlock.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }

    Text {
      text: Model.clockDuration(totalBlock.seconds)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
    }
  }

  component ProjectTotal: Item {
    id: totalRow
    property string project: ""
    property int seconds: 0
    readonly property real share: root.punch && root.punch.todaySeconds > 0
      ? seconds / root.punch.todaySeconds : 0

    implicitHeight: totalLabel.implicitHeight + Style.space(8)

    // A proportional wash behind the row, so the shape of the day reads
    // before any of the numbers do.
    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(Style.space(2), parent.width * totalRow.share)
      height: parent.height
      radius: Style.cornerRadius
      color: Util.alpha(root.projectColor(totalRow.project), 0.14)
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Rectangle {
        width: Style.space(6)
        height: Style.space(6)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: root.projectColor(totalRow.project)
      }

      Text {
        id: totalLabel
        text: totalRow.project
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: Model.clockDuration(totalRow.seconds)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  component EntryRow: CursorSurface {
    id: entryRow
    property var entry: null
    property int rowIndex: 0
    readonly property bool live: entry && entry.id === "running"

    hasCursor: root.cursorActive && root.cursor === rowIndex
    foreground: root.foreground
    implicitHeight: entryContent.implicitHeight + Style.space(10)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursor = entryRow.rowIndex }
      onClicked: root.activateCursor()
    }

    RowLayout {
      id: entryContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        width: Style.space(3)
        height: Style.space(20)
        radius: width / 2
        color: entryRow.entry ? root.projectColor(entryRow.entry.project) : root.dim
        opacity: entryRow.live ? 1.0 : 0.7
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        Text {
          Layout.fillWidth: true
          text: entryRow.entry ? entryRow.entry.project : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: {
            if (!entryRow.entry) return ""
            var range = Model.clockTime(entryRow.entry.start) + "–" + (entryRow.live ? "now" : Model.clockTime(entryRow.entry.end))
            return entryRow.entry.note ? range + "  " + entryRow.entry.note : range
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        Layout.alignment: Qt.AlignVCenter
        text: entryRow.entry ? Model.clockDuration(entryRow.entry.end - entryRow.entry.start) : ""
        color: entryRow.live ? root.activeColor : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        visible: !entryRow.live
        iconText: "󰧧"
        tooltipText: "Delete entry"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        onClicked: if (root.punch && entryRow.entry) root.punch.deleteEntry(entryRow.entry.id)
      }
    }
  }
}
