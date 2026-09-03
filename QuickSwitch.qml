import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The fast path. One keybind, one input, no chrome: type enough of a
// project to tell it apart, press enter, the clock is running. Everything
// else the switcher can do — creating a project, backdating, attaching a
// note, stopping — is reachable without lifting your hands off the keys.
Item {
  id: root

  // Injected by the omarchy-shell panel loader.
  property var shell: null
  property var manifest: null
  property var service: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property bool opened: false
  property string filterText: ""
  property int cursor: 0

  readonly property string fontFamily: Style.font.menuFamily
  readonly property color foreground: Color.menu.text
  readonly property color background: Color.menu.background
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  readonly property var parsed: Model.parseQuickInput(filterText)
  // Read the running entry through one property and test *that* everywhere.
  // Deriving a boolean first and dereferencing later leaves a window where
  // the boolean is still true and the entry is already gone.
  readonly property var live: service && service.running ? service.running : null
  readonly property bool tracking: live !== null

  // A line that is nothing but a note — ": pairing on the indexer" — means
  // "say this about what I am already doing", not "start something". Reuses
  // the grammar and the keybind that already exist rather than inventing a
  // second way in.
  readonly property bool noteOnly: !parsed.project && parsed.note.length > 0 && live !== null

  // Today's totals, so the list answers "how long have I been on this
  // already" at the same moment it asks which project you want.
  readonly property var todayByProject: {
    // Null prototype: a project named "constructor" is a project.
    var map = Object.create(null)
    if (!service) return map
    var totals = Model.byProject(service.todayEntries)
    for (var i = 0; i < totals.length; i++) map[totals[i].project.toLowerCase()] = totals[i].seconds
    var current = service.running
    if (current) {
      var key = String(current.project).toLowerCase()
      map[key] = (map[key] || 0) + service.elapsed
    }
    return map
  }

  // Stop first, matches first, create last. The stop row only appears on an
  // empty filter: once you are typing a name you are switching, not stopping.
  readonly property var rows: {
    var out = []
    if (noteOnly)
      return [{ kind: "note", label: "Note: " + parsed.note, meta: live.project }]

    var current = live
    if (current && !parsed.project)
      out.push({ kind: "stop", label: "Stop " + current.project, meta: Model.clockDuration(service.elapsed) })

    var ranked = service ? Model.rankProjects(service.projects, parsed.project) : []
    for (var i = 0; i < ranked.length; i++) {
      var seconds = todayByProject[ranked[i].name.toLowerCase()] || 0
      out.push({
        kind: "project",
        name: ranked[i].name,
        label: ranked[i].name,
        meta: seconds ? Model.clockDuration(seconds) + " today" : ""
      })
    }

    var exact = service ? Model.findProject(service.projects, parsed.project) : null
    if (parsed.project && !exact)
      out.push({ kind: "create", name: parsed.project, label: "Create " + parsed.project, meta: "new" })

    // A launcher that scrolls is a launcher you are reading instead of
    // typing at. Nine rows, then type another letter.
    return out.length > 9 ? out.slice(0, 9) : out
  }

  readonly property string hint: {
    if (noteOnly) return "note this on " + live.project
    if (parsed.backdateMinutes > 0 && parsed.note)
      return "starts " + parsed.backdateMinutes + " min ago · " + parsed.note
    if (parsed.backdateMinutes > 0) return "starts " + parsed.backdateMinutes + " min ago"
    if (parsed.note) return parsed.note
    return "name +minutes : note"
  }

  readonly property int rowHeight: Math.max(Style.spacing.popupRowHeight, Style.font.body + Style.space(12))
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.heading + Style.space(12))
  readonly property int listHeight: rows.length
    ? rows.length * rowHeight + (rows.length - 1) * Style.space(2)
    : Style.space(44)
  readonly property int cardContentHeight: headerHeight + listHeight + Style.font.caption
    + 2 * Style.spacing.hairline + 4 * Style.space(10)

  function projectColor(name) {
    if (!name) return foreground
    return Qt.hsla(Model.projectHue(name), 0.52, 0.62, 1.0)
  }

  function open(payloadJson) {
    filterText = ""
    cursor = 0
    opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    opened = false
  }

  function dismiss() {
    opened = false
    if (shell && typeof shell.hide === "function")
      shell.hide(manifest && manifest.id ? manifest.id : "pb.punch")
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  function setFilter(next) {
    filterText = next
    cursor = 0
  }

  function moveCursor(delta) {
    if (!rows.length) { cursor = 0; return }
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + delta))
  }

  function submit() {
    if (!service) { dismiss(); return }
    var row = rows.length ? rows[Math.max(0, Math.min(rows.length - 1, cursor))] : null
    if (!row) { dismiss(); return }

    if (row.kind === "stop") {
      service.stop()
      dismiss()
      return
    }
    if (row.kind === "note") {
      service.setNote(parsed.note)
      dismiss()
      return
    }
    // The typed text carries the note and the backdate; the row only ever
    // decides *which* project, so picking an existing one and inventing a
    // new one land in exactly the same call.
    service.start(row.name, parsed.note, parsed.backdateMinutes)
    dismiss()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "punch-quick-switch"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(520), panel.width - Style.gapsOut * 2)
      height: Math.min(root.cardContentHeight + Style.spacing.panelPadding * 2
                         + Border.top(root.borderSpec) + Border.bottom(root.borderSpec),
                       panel.height - Style.gapsOut * 2)
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier))) {
            root.moveCursor(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier))) {
            root.moveCursor(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.submit()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                     && !(event.modifiers & Qt.ControlModifier)) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(10)

        Item {
          id: header
          width: parent.width
          height: root.headerHeight

          Text {
            id: prompt
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍉"
            color: root.live ? root.projectColor(root.live.project) : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Text {
            anchors.left: prompt.right
            anchors.leftMargin: Style.space(10)
            anchors.right: hintText.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Track what?"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }

          Text {
            id: hintText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width * 0.4)
            text: root.hint
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          id: list
          width: parent.width
          spacing: Style.space(2)

          Text {
            visible: root.rows.length === 0
            width: parent.width
            text: "No projects yet. Type a name and press enter."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            topPadding: Style.space(10)
            bottomPadding: Style.space(10)
            horizontalAlignment: Text.AlignHCenter
          }

          Repeater {
            model: root.rows
            SwitchRow {
              required property var modelData
              required property int index
              width: list.width
              row: modelData
              rowIndex: index
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Text {
          id: footer
          width: parent.width
          text: "enter start · :note on the running entry · ctrl+n/p move · esc close"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  component SwitchRow: CursorSurface {
    id: switchRow
    property var row: null
    property int rowIndex: 0

    hasCursor: root.cursor === rowIndex
    foreground: root.foreground
    implicitHeight: root.rowHeight

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.cursor = switchRow.rowIndex
      onClicked: { root.cursor = switchRow.rowIndex; root.submit() }
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Rectangle {
        width: Style.space(7)
        height: Style.space(7)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        visible: switchRow.row && switchRow.row.kind !== "stop" && switchRow.row.kind !== "note"
        color: switchRow.row ? root.projectColor(switchRow.row.name) : root.dim
        opacity: switchRow.row && switchRow.row.kind === "create" ? 0.45 : 1.0
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: switchRow.row && (switchRow.row.kind === "stop" || switchRow.row.kind === "note")
        text: switchRow.row && switchRow.row.kind === "note" ? "󰲶" : "󰓛"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        id: label
        anchors.verticalCenter: parent.verticalCenter
        text: switchRow.row ? switchRow.row.label : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: switchRow.row ? switchRow.row.meta : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
