// Bar-widget UI for the Torrents plugin: the magnet icon shown in the bar,
// and the popup panel with the torrent list, add/upload controls, and the
// client add/edit/remove settings screen. All actual state and backend
// calls live in Service.qml (instantiated below as `torrents`) -- this file
// only reads its properties and calls its functions, and never spawns a
// process directly.
//
// `pragma ComponentBehavior: Bound` (required by the inline `component`
// blocks below) makes id references from an enclosing scope, such as
// `root.foreground` inside TorrentRow, resolve at compile time instead of
// through a runtime scope chain. Without it, ListView/Repeater can recycle
// delegate instances without properly rebinding those references, which
// previously left click handlers on the torrent list silently inert.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "widget.torrents"
  ipcTarget: "widget.torrents"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool anyActive: {
    var list = torrents.torrents
    for (var i = 0; i < list.length; i++) {
      if (list[i].status === "downloading" || list[i].status === "checking") return true
    }
    return false
  }
  readonly property color barIconColor: torrents.clients.length === 0
    ? Qt.darker(barForeground, 1.7)
    : (anyActive ? Color.accent : barForeground)

  // ---- client add/edit form state ----
  // The form* properties mirror one client's fields while the add/edit
  // dialog is open, committed to Service via saveForm(). formPassword always
  // starts blank on edit -- the backend never sends a saved password back to
  // the UI, so there is nothing to prefill; leaving it blank on save means
  // "keep what's already stored" (see Service.saveClient).
  property bool showSettings: false
  property var editingClient: null  // {} for a new client, an existing client object to edit, or null (form closed)
  property bool formSubmitted: false
  property bool formWasNewClient: false
  property string formName: ""
  property string formKind: "transmission"
  property string formHost: ""
  property string formPort: ""
  property string formPath: ""
  property string formUsername: ""
  property string formPassword: ""
  property bool formSsl: false
  property string magnetInput: ""

  // ---- shared "are you sure?" dialog state (torrent or client removal) ----
  property string confirmKind: ""  // "", "remove-torrent", "remove-client"
  property string confirmTargetId: ""
  property string confirmTargetName: ""
  readonly property string confirmMessage: confirmKind === "remove-torrent"
    ? ("Remove \"" + confirmTargetName + "\" from " + (torrents.selectedClient ? torrents.selectedClient.name : "the client") + "?\nThis does not delete downloaded files.")
    : (confirmKind === "remove-client" ? ("Remove the saved connection \"" + confirmTargetName + "\"?") : "")

  function defaultPortFor(kind) {
    if (kind === "qbittorrent") return 8080
    if (kind === "deluge") return 8112
    return 9091
  }

  function openAddClientForm() {
    editingClient = {}
    formName = ""
    formKind = "transmission"
    formHost = ""
    formPort = String(defaultPortFor("transmission"))
    formPath = ""
    formUsername = ""
    formPassword = ""
    formSsl = false
    torrents.probeResult = null
    showSettings = true
  }

  function openEditClientForm(c) {
    editingClient = c
    formName = c.name
    formKind = c.kind
    formHost = c.host
    formPort = String(c.port)
    formPath = c.path || ""
    formUsername = c.username || ""
    formPassword = ""
    formSsl = !!c.ssl
    torrents.probeResult = null
    showSettings = true
  }

  function closeClientForm() {
    editingClient = null
    torrents.probeResult = null
  }

  function currentFormFields() {
    return {
      name: formName.trim(),
      kind: formKind,
      host: formHost.trim(),
      port: parseInt(formPort, 10) || defaultPortFor(formKind),
      path: formPath.trim(),
      username: formUsername.trim(),
      password: formPassword,
      ssl: formSsl
    }
  }

  function saveForm() {
    formSubmitted = true
    formWasNewClient = !(editingClient && editingClient.id)
    torrents.saveClient(currentFormFields(), (editingClient && editingClient.id) ? editingClient.id : "")
  }

  function submitMagnet() {
    var uri = magnetInput.trim()
    if (uri === "") return
    torrents.addMagnet(uri)
    magnetInput = ""
  }

  function confirmRemoveTorrent(t) {
    confirmKind = "remove-torrent"
    confirmTargetId = t.id
    confirmTargetName = t.name
  }

  function confirmRemoveClient(c) {
    confirmKind = "remove-client"
    confirmTargetId = c.id
    confirmTargetName = c.name
  }

  Service {
    id: torrents
    settings: root.settings
  }

  Connections {
    target: torrents
    function onBusyOpChanged() {
      if (root.formSubmitted && torrents.busyOp === "") {
        root.formSubmitted = false
        if (torrents.actionMessage === "") {
          root.closeClientForm()
          if (root.formWasNewClient) {
            root.showSettings = false
            torrents.refreshStatus()
          }
        }
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    torrents.refreshClients()
    torrents.refreshStatus()
    if (torrents.clients.length === 0) showSettings = true
  } else {
    confirmKind = ""
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""

    onPressed: function(b) {
      if (b === Qt.RightButton) torrents.refreshStatus()
      else if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.confirmKind !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- hero: icon, title, speed totals, alt-speed toggle, settings cog ----
          Item {
            id: hero
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

            Text {
              id: heroIcon
              text: ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              opacity: torrents.clients.length > 0 ? 1.0 : 0.5
            }

            RowLayout {
              id: heroActions
              spacing: Style.space(6)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              Text {
                visible: !root.showSettings && !!torrents.selectedClient
                text: "↓ " + Model.formatSpeed(torrents.totals.down) + "   ↑ " + Model.formatSpeed(torrents.totals.up)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                Layout.alignment: Qt.AlignVCenter
              }

              PanelActionButton {
                id: altSpeedButton
                visible: !root.showSettings && !!torrents.selectedClient
                iconText: ""
                tooltipText: (torrents.altSpeedEnabled ? "Turn off" : "Turn on") + " temporary speed limit"
                foreground: torrents.altSpeedEnabled ? Color.accent : Qt.darker(root.foreground, 2.0)
                fontFamily: root.fontFamily
                enabled: !torrents.altSpeedBusy
                onClicked: torrents.toggleAltSpeed()
              }

              PanelActionButton {
                iconText: root.showSettings ? "" : ""
                tooltipText: root.showSettings ? "Back to torrents" : "Manage clients"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  if (root.showSettings) root.closeClientForm()
                  root.showSettings = !root.showSettings || torrents.clients.length === 0
                  if (!root.showSettings) torrents.refreshStatus()
                }
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: heroActions.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: "Torrents"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.showSettings
                  ? "Manage torrent client connections"
                  : (torrents.clients.length > 0
                    ? Model.activityLabel(torrents.overallActivityStatus)
                    : "No client configured")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          // ---- client switcher (only shown with 2+ configured clients) ----
          Row {
            visible: !root.showSettings && torrents.clients.length > 1
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: torrents.clients
              Button {
                required property var modelData
                text: modelData.name
                bordered: true
                selected: modelData.id === torrents.selectedClientId
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: torrents.selectClient(modelData.id)
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // ==== Torrents view ====
          Column {
            visible: !root.showSettings
            width: parent.width
            spacing: Style.space(10)

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              visible: !!torrents.selectedClient

              TextField {
                id: magnetField
                Layout.fillWidth: true
                foreground: root.foreground
                placeholderText: "Magnet link or .torrent URL"
                text: root.magnetInput
                onTextChanged: root.magnetInput = text
                Keys.onReturnPressed: root.submitMagnet()
              }

              Button {
                text: "Add"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.magnetInput.trim() !== "" && torrents.busyOp === ""
                onClicked: root.submitMagnet()
              }

              PanelActionButton {
                iconText: ""
                tooltipText: "Upload a .torrent file"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: torrents.busyOp === ""
                onClicked: torrents.pickTorrentFile()
              }
            }

            Text {
              visible: torrents.actionMessage !== ""
              width: parent.width
              text: torrents.actionMessage
              color: root.urgentColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !torrents.selectedClient
              width: parent.width
              text: "No torrent client configured yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: !!torrents.selectedClient && torrents.lastError !== ""
              width: parent.width
              text: torrents.lastError
              color: root.urgentColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !!torrents.selectedClient && torrents.lastError === "" && torrents.everLoaded && torrents.torrents.length === 0
              width: parent.width
              text: "No torrents on this client."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Item {
              id: torrentListWrapper
              visible: !!torrents.selectedClient && torrents.torrents.length > 0
              width: parent.width
              height: torrentList.height

              ListView {
                id: torrentList
                anchors.left: parent.left
                anchors.right: scrollTrack.visible ? scrollTrack.left : parent.right
                anchors.rightMargin: scrollTrack.visible ? Style.space(6) : 0
                height: Math.min(contentHeight, Style.space(360))
                spacing: Style.space(6)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: torrents.torrents

                delegate: TorrentRow {
                  required property var modelData
                  width: torrentList.width
                  torrent: modelData
                }
              }

              // Custom scrollbar: always clickable and draggable, unlike the
              // default QQC ScrollBar which auto-hides and can lose the drag
              // gesture to the surrounding panel Flickable.
              Item {
                id: scrollTrack
                visible: torrentList.contentHeight > torrentList.height
                anchors.top: torrentList.top
                anchors.bottom: torrentList.bottom
                anchors.right: parent.right
                width: Style.space(6)

                readonly property real maxScroll: Math.max(1, torrentList.contentHeight - torrentList.height)
                readonly property real handleHeight: Math.max(Style.space(24), height * (torrentList.height / Math.max(1, torrentList.contentHeight)))
                readonly property real maxHandleY: Math.max(0, height - handleHeight)

                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  color: Style.hoverFillFor(root.foreground, Color.accent)
                }

                Rectangle {
                  id: scrollHandle
                  width: parent.width
                  height: scrollTrack.handleHeight
                  radius: width / 2
                  y: scrollTrack.maxHandleY * (torrentList.contentY / scrollTrack.maxScroll)
                  color: root.foreground
                  opacity: trackMouse.pressed || trackMouse.containsMouse ? 1.0 : 0.6

                  Behavior on opacity { NumberAnimation { duration: 100 } }
                }

                MouseArea {
                  id: trackMouse
                  anchors.fill: parent
                  anchors.leftMargin: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  preventStealing: true

                  function scrollToPointerY(pointerY) {
                    var target = pointerY - scrollTrack.handleHeight / 2
                    target = Math.max(0, Math.min(scrollTrack.maxHandleY, target))
                    var ratio = scrollTrack.maxHandleY > 0 ? target / scrollTrack.maxHandleY : 0
                    torrentList.contentY = ratio * scrollTrack.maxScroll
                  }

                  onPressed: function(mouse) { scrollToPointerY(mouse.y) }
                  onPositionChanged: function(mouse) { if (pressed) scrollToPointerY(mouse.y) }
                }
              }
            }
          }

          // ==== Settings / manage clients view ====
          Column {
            visible: root.showSettings
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              visible: !root.editingClient
              text: "CONFIGURED CLIENTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              visible: !root.editingClient
              width: parent.width
              spacing: Style.space(6)

              Text {
                visible: torrents.clients.length === 0
                width: parent.width
                text: "No torrent clients configured yet."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
              }

              Repeater {
                model: torrents.clients
                ClientRow {
                  required property var modelData
                  width: parent.width
                  client: modelData
                }
              }
            }

            Button {
              visible: !root.editingClient
              text: "Add a client"
              iconText: ""
              bordered: true
              leftAlign: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              width: parent.width
              onClicked: root.openAddClientForm()
            }

            // ---- add/edit form ----
            Column {
              visible: !!root.editingClient
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: (root.editingClient && root.editingClient.id) ? "EDIT CLIENT" : "ADD CLIENT"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              LabeledField {
                width: parent.width
                label: "Name"
                text: root.formName
                onTextEdited: root.formName = text
              }

              Dropdown {
                width: parent.width
                label: "Client type"
                value: root.formKind
                options: [
                  { value: "transmission", label: "Transmission" },
                  { value: "qbittorrent", label: "qBittorrent" },
                  { value: "deluge", label: "Deluge" }
                ]
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(v) {
                  root.formKind = v
                  if (!(root.editingClient && root.editingClient.id)) root.formPort = String(root.defaultPortFor(v))
                }
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(10)

                LabeledField {
                  Layout.fillWidth: true
                  label: "Host"
                  text: root.formHost
                  onTextEdited: root.formHost = text
                }

                LabeledField {
                  Layout.preferredWidth: Style.space(90)
                  label: "Port"
                  text: root.formPort
                  onTextEdited: root.formPort = text.replace(/[^0-9]/g, "").slice(0, 5)
                }
              }

              LabeledField {
                visible: root.formKind === "transmission"
                width: parent.width
                label: "RPC path"
                placeholderText: "/transmission/rpc"
                text: root.formPath
                onTextEdited: root.formPath = text
              }

              LabeledField {
                visible: root.formKind !== "deluge"
                width: parent.width
                label: "Username"
                text: root.formUsername
                onTextEdited: root.formUsername = text
              }

              LabeledField {
                width: parent.width
                label: "Password"
                password: true
                placeholderText: (root.editingClient && root.editingClient.id) ? "Leave blank to keep saved password" : ""
                text: root.formPassword
                onTextEdited: root.formPassword = text
              }

              Toggle {
                width: parent.width
                label: "Use HTTPS"
                checked: root.formSsl
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.formSsl = !root.formSsl
              }

              Text {
                visible: torrents.probeResult !== null
                width: parent.width
                text: torrents.probeResult
                  ? (torrents.probeResult.ok
                    ? ("Connected — " + torrents.probeResult.torrentCount + " torrent(s) found")
                    : ("Connection failed: " + torrents.probeResult.error))
                  : ""
                color: torrents.probeResult && torrents.probeResult.ok ? root.foreground : root.urgentColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  text: torrents.probing ? "Testing…" : "Test connection"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: root.formHost.trim() !== "" && !torrents.probing
                  onClicked: torrents.probeConnection(root.currentFormFields(), (root.editingClient && root.editingClient.id) ? root.editingClient.id : "")
                }

                Item { Layout.fillWidth: true }

                Button {
                  text: "Cancel"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.closeClientForm()
                }

                Button {
                  text: torrents.busyOp === "save-client" ? "Saving…" : "Save"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: root.formName.trim() !== "" && root.formHost.trim() !== "" && torrents.busyOp === ""
                  onClicked: root.saveForm()
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.confirmKind !== ""
        message: root.confirmMessage
        confirmText: "Remove"
        foreground: root.foreground
        background: Color.popups.background
        onCanceled: root.confirmKind = ""
        onConfirmed: {
          if (root.confirmKind === "remove-torrent") torrents.torrentAction([root.confirmTargetId], "remove")
          else if (root.confirmKind === "remove-client") torrents.removeClient(root.confirmTargetId)
          root.confirmKind = ""
        }
      }
    }
  }

  // ==== reusable row components ====
  // Small building blocks specific to this panel (a plain qs.Ui.TextField
  // with a caption label, and the two list-row layouts), defined inline
  // with QML's `component` keyword rather than as separate files since
  // nothing outside this panel uses them.

  component LabeledField: Column {
    property alias label: labelText.text
    property alias text: field.text
    property alias placeholderText: field.placeholderText
    property bool password: false
    signal textEdited()

    spacing: Style.spacing.labelGap

    Text {
      id: labelText
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    TextField {
      id: field
      width: parent.width
      foreground: root.foreground
      password: parent.password
      onTextChanged: parent.textEdited()
    }
  }

  component TorrentRow: BorderSurface {
    id: row
    property var torrent: null
    readonly property var statusInfo: Model.statusInfo(torrent ? torrent.status : "unknown")
    readonly property color statusColor: {
      if (statusInfo.role === "accent") return Color.accent
      if (statusInfo.role === "urgent") return root.urgentColor
      if (statusInfo.role === "foreground") return root.foreground
      return root.dim
    }
    readonly property color progressColor: statusInfo.role === "muted" ? root.foreground : statusColor
    readonly property real progressOpacity: statusInfo.role === "muted" ? 0.5 : 1.0
    readonly property bool isPaused: torrent && torrent.status === "paused"

    implicitHeight: content.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: rowHover.hovered ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
    borderSpec: Border.none()

    HoverHandler { id: rowHover }

    Column {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(8)
      spacing: Style.space(4)

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Text {
          Layout.fillWidth: true
          text: row.torrent ? row.torrent.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          text: row.statusInfo.text
          color: row.statusColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        PanelActionButton {
          iconText: row.isPaused ? "" : ""
          tooltipText: row.isPaused ? "Resume" : "Pause"
          foreground: root.foreground
          fontFamily: root.fontFamily
          size: Style.space(20)
          fontSize: Style.font.caption
          enabled: torrents.busyOp === ""
          onClicked: torrents.torrentAction([row.torrent.id], row.isPaused ? "resume" : "pause")
        }

        PanelActionButton {
          iconText: ""
          tooltipText: "Remove"
          hoverColor: root.urgentColor
          foreground: root.foreground
          fontFamily: root.fontFamily
          size: Style.space(20)
          fontSize: Style.font.caption
          enabled: torrents.busyOp === ""
          onClicked: root.confirmRemoveTorrent(row.torrent)
        }
      }

      Item {
        width: parent.width
        height: Style.space(5)

        Rectangle {
          anchors.fill: parent
          radius: height / 2
          color: Style.hoverFillFor(root.foreground, Color.accent)
        }

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: parent.width * Math.max(0, Math.min(1, row.torrent ? row.torrent.progress : 0))
          radius: height / 2
          color: row.progressColor
          opacity: row.progressOpacity
        }
      }

      Text {
        width: parent.width
        text: {
          if (!row.torrent) return ""
          var t = row.torrent
          return Model.formatPercent(t.progress) + "  ·  " + Model.formatBytes(t.sizeBytes)
            + "  ·  ↓ " + Model.formatSpeed(t.downloadRate) + "  ·  ↑ " + Model.formatSpeed(t.uploadRate)
            + "  ·  ETA " + Model.formatEta(t.eta) + "  ·  ratio " + Model.formatRatio(t.ratio)
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        visible: row.torrent && row.torrent.error !== ""
        width: parent.width
        text: row.torrent ? row.torrent.error : ""
        color: root.urgentColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  component ClientRow: Item {
    id: clientRow
    property var client: null
    implicitHeight: clientRowLayout.implicitHeight + Style.space(8)

    RowLayout {
      id: clientRowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        Text {
          Layout.fillWidth: true
          text: clientRow.client ? clientRow.client.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: {
            var c = clientRow.client
            return c ? (Model.kindLabel(c.kind) + " · " + c.host + ":" + c.port) : ""
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: ""
        tooltipText: "Edit"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.openEditClientForm(clientRow.client)
      }

      PanelActionButton {
        iconText: ""
        tooltipText: "Remove"
        hoverColor: root.urgentColor
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.confirmRemoveClient(clientRow.client)
      }
    }
  }
}
