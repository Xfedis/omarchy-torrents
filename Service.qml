import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Backend service for the Torrents plugin. Owns all state (configured
// clients, the selected client's torrent list, in-flight operations) and is
// the only place that talks to helper.py, always via a Quickshell Process
// with its full argv in a plain array -- never through a shell string, so
// there's no shell-injection surface regardless of what a client name, host,
// or magnet link contains. Panel.qml only reads this component's properties
// and calls its functions; it never spawns a process itself.
Item {
  id: root

  property var settings: ({})

  function localFilePath(url) {
    var s = String(url)
    return s.indexOf("file://") === 0 ? s.substring(7) : s
  }

  // Resolved relative to this file, so it works whether the plugin is
  // running from its installed location or a cloned copy under
  // ~/.config/omarchy/plugins/.
  readonly property string helperPath: localFilePath(Qt.resolvedUrl("helper.py"))

  // ---- configured clients -------------------------------------------

  property var clients: []
  property string selectedClientId: ""
  readonly property var selectedClient: clientById(selectedClientId)

  // ---- selected client's live torrent state --------------------------

  property var torrents: []
  property var totals: ({ down: 0, up: 0 })
  property bool loading: false
  property bool clientsLoading: false
  property string lastError: ""
  property bool everLoaded: false
  property bool altSpeedEnabled: false
  property bool altSpeedBusy: false

  // ---- background activity polling (all clients, for the Idle/Seeding/
  // Downloading status shown in the panel header) -----------------------
  // The selected client's own totals (above) already come from statusProc
  // on every tick; every other configured client is polled one at a time,
  // round-robin, one per tick, to avoid firing N processes at once.
  property var clientActivity: ({})  // id -> { down, up }, excludes selectedClientId
  property int nextActivityIndex: 0
  property string pendingActivityClientId: ""

  readonly property bool anyDownloadActivity: {
    if ((totals.down || 0) > 0) return true
    for (var id in clientActivity) { if ((clientActivity[id].down || 0) > 0) return true }
    return false
  }
  readonly property bool anyUploadActivity: {
    if ((totals.up || 0) > 0) return true
    for (var id in clientActivity) { if ((clientActivity[id].up || 0) > 0) return true }
    return false
  }
  // Downloading wins over seeding when both are happening at once.
  readonly property string overallActivityStatus: anyDownloadActivity ? "downloading" : (anyUploadActivity ? "seeding" : "idle")

  function pruneClientActivity() {
    var ids = {}
    for (var i = 0; i < clients.length; i++) ids[clients[i].id] = true
    var pruned = {}
    for (var id in clientActivity) { if (ids[id]) pruned[id] = clientActivity[id] }
    clientActivity = pruned
  }

  function pollNextClientActivity() {
    if (activityProc.running) return
    var others = clients.filter(function(c) { return c.id !== selectedClientId })
    if (others.length === 0) return
    if (nextActivityIndex >= others.length) nextActivityIndex = 0
    var target = others[nextActivityIndex]
    nextActivityIndex++
    pendingActivityClientId = target.id
    runHelper(activityProc, ["status", "--id", target.id])
  }

  // ---- in-flight operation tracking -----------------------------------

  property string busyOp: ""  // "", "add-magnet", "add-file", "action:<op>", "save-client", "remove-client"
  property string actionMessage: ""
  property var probeResult: null  // { ok, error, torrentCount } or null while pending
  property bool probing: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 3)), 10)
    if (!isFinite(n) || n < 2) n = 3
    return n
  }

  function clientById(id) {
    for (var i = 0; i < clients.length; i++) {
      if (clients[i].id === id) return clients[i]
    }
    return null
  }

  function ensureSelectedClient() {
    if (clients.length === 0) { selectedClientId = ""; return }
    if (!clientById(selectedClientId)) selectedClientId = clients[0].id
  }

  function selectClient(id) {
    if (id === selectedClientId) return
    selectedClientId = id
    torrents = []
    everLoaded = false
    lastError = ""
    altSpeedEnabled = false
    refreshStatus()
  }

  // ---- process runners -----------------------------------------------

  function runHelper(process, args) {
    process.command = ["python3", root.helperPath].concat(args)
    process.running = true
  }

  function refreshClients() {
    if (clientsProc.running) return
    clientsLoading = true
    runHelper(clientsProc, ["clients"])
  }

  function refreshStatus() {
    if (!selectedClientId || statusProc.running) return
    loading = true
    runHelper(statusProc, ["status", "--id", selectedClientId])
  }

  function addMagnet(uri) {
    if (!selectedClientId || busyOp !== "") return
    busyOp = "add-magnet"
    actionMessage = "Adding magnet link…"
    runHelper(magnetProc, ["add-magnet", "--id", selectedClientId, "--magnet", uri])
  }

  function addTorrentFile(path) {
    if (!selectedClientId || busyOp !== "") return
    busyOp = "add-file"
    actionMessage = "Uploading torrent…"
    runHelper(fileAddProc, ["add-file", "--id", selectedClientId, "--path", path])
  }

  function pickTorrentFile() {
    if (filePickProc.running) return
    filePickProc.running = true
  }

  function torrentAction(ids, op) {
    if (!selectedClientId || ids.length === 0 || busyOp !== "") return
    busyOp = "action:" + op
    runHelper(actionProc, ["torrent-action", "--id", selectedClientId, "--op", op, "--torrent-ids", ids.join(",")])
  }

  function setAltSpeedEnabled(enabled) {
    if (!selectedClientId || altSpeedBusy) return
    altSpeedBusy = true
    // Optimistic: flip immediately so the icon reacts on click rather than
    // waiting for the round trip; refreshStatus() below corrects it if the
    // call actually failed.
    altSpeedEnabled = enabled
    runHelper(altSpeedProc, ["set-alt-speed", "--id", selectedClientId, "--enabled", enabled ? "true" : "false"])
  }

  function toggleAltSpeed() {
    setAltSpeedEnabled(!altSpeedEnabled)
  }

  // fields: {name, kind, host, port, path, username, password, ssl}. existingId set = update.
  function saveClient(fields, existingId) {
    if (busyOp !== "") return
    busyOp = "save-client"
    _savedNewClient = !existingId
    var args = ["add-client", "--name", fields.name, "--kind", fields.kind,
                "--host", fields.host, "--port", String(fields.port),
                "--path", fields.path || "", "--username", fields.username || ""]
    if (existingId) args = args.concat(["--id", existingId])
    if (fields.ssl) args.push("--ssl")
    // Editing with a blank password field means "keep the saved password"
    // (that's what the form's placeholder promises) -- only send a password
    // when adding a new client or when the user actually typed one in.
    // See helper.py's --password definition for why this goes over argv.
    var sendPassword = !existingId || (fields.password !== undefined && fields.password !== null && fields.password !== "")
    if (sendPassword) args = args.concat(["--password", fields.password || ""])
    saveClientProc.command = ["python3", root.helperPath].concat(args)
    saveClientProc.running = true
  }

  property bool _savedNewClient: false

  function removeClient(id) {
    if (busyOp !== "") return
    busyOp = "remove-client"
    runHelper(removeClientProc, ["remove-client", "--id", id])
  }

  // fields as above, no id (ad-hoc test before saving).
  // existingId: pass the client being edited so a blank password field
  // tests against the already-saved password instead of no credentials.
  // See helper.py's --password definition for why it goes over argv.
  function probeConnection(fields, existingId) {
    probeResult = null
    probing = true
    var args = ["probe", "--kind", fields.kind, "--host", fields.host, "--port", String(fields.port),
                "--path", fields.path || "", "--username", fields.username || "",
                "--password", fields.password || ""]
    if (fields.ssl) args.push("--ssl")
    if (existingId) args = args.concat(["--id", existingId])
    probeProc.command = ["python3", root.helperPath].concat(args)
    probeProc.running = true
  }

  // ---- process wiring ---------------------------------------------------

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      if (root.clients.length === 0) root.refreshClients()
      root.refreshStatus()
      root.pollNextClientActivity()
    }
  }

  Component.onCompleted: root.refreshClients()

  Process {
    id: clientsProc
    stdout: StdioCollector {
      id: clientsStdout
      waitForEnd: true
      onStreamFinished: {
        root.clientsLoading = false
        var parsed = Model.parseJsonLine(text)
        if (parsed && parsed.ok) {
          root.clients = parsed.clients || []
          root.pruneClientActivity()
          root.ensureSelectedClient()
          if (root.selectedClientId && root.torrents.length === 0 && !root.everLoaded) root.refreshStatus()
        }
      }
    }
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        root.everLoaded = true
        var parsed = Model.parseJsonLine(text)
        if (!parsed) {
          root.lastError = "No response from helper"
          return
        }
        if (parsed.ok) {
          root.torrents = Model.sortTorrents(parsed.torrents || [])
          root.totals = parsed.totals || { down: 0, up: 0 }
          if (!root.altSpeedBusy) root.altSpeedEnabled = !!parsed.altSpeedEnabled
          root.lastError = ""
        } else {
          root.lastError = parsed.error || "Failed to load torrents"
          root.torrents = []
        }
      }
    }
  }

  Process {
    id: magnetProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busyOp = ""
        var parsed = Model.parseJsonLine(text)
        root.actionMessage = (parsed && parsed.ok) ? "" : ("Failed to add magnet: " + (parsed ? parsed.error : "unknown error"))
        root.refreshStatus()
        if (root.actionMessage !== "") actionMessageTimer.restart()
      }
    }
  }

  Process {
    id: fileAddProc
    stdout: StdioCollector { id: fileAddStdout; waitForEnd: true }
    stderr: StdioCollector { id: fileAddStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busyOp = ""
      var parsed = Model.parseJsonLine(fileAddStdout.text)
      root.actionMessage = (parsed && parsed.ok) ? "" : ("Failed to upload torrent: " + (parsed ? parsed.error : "unknown error"))
      root.refreshStatus()
      if (root.actionMessage !== "") actionMessageTimer.restart()
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busyOp = ""
      var parsed = Model.parseJsonLine(actionStdout.text)
      if (!(parsed && parsed.ok)) {
        root.actionMessage = "Action failed: " + (parsed ? parsed.error : "unknown error")
        actionMessageTimer.restart()
      }
      root.refreshStatus()
    }
  }

  Process {
    id: altSpeedProc
    stdout: StdioCollector { id: altSpeedStdout; waitForEnd: true }
    stderr: StdioCollector { id: altSpeedStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.altSpeedBusy = false
      var parsed = Model.parseJsonLine(altSpeedStdout.text)
      if (!(parsed && parsed.ok)) {
        root.actionMessage = "Speed limit toggle failed: " + (parsed ? parsed.error : "unknown error")
        actionMessageTimer.restart()
      }
      root.refreshStatus()
    }
  }

  Process {
    id: saveClientProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busyOp = ""
        var parsed = Model.parseJsonLine(text)
        if (parsed && parsed.ok) {
          root.clients = parsed.clients || []
          // A brand-new client is always appended last by the helper; jump
          // straight to it so the user sees it connect rather than whatever
          // was selected before.
          if (root._savedNewClient && root.clients.length > 0) {
            root.selectedClientId = root.clients[root.clients.length - 1].id
          }
          root.ensureSelectedClient()
          root.actionMessage = ""
        } else {
          root.actionMessage = "Failed to save client: " + (parsed ? parsed.error : "unknown error")
          actionMessageTimer.restart()
        }
      }
    }
  }

  Process {
    id: removeClientProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busyOp = ""
        var parsed = Model.parseJsonLine(text)
        if (parsed && parsed.ok) {
          root.clients = parsed.clients || []
          root.pruneClientActivity()
          root.ensureSelectedClient()
          root.refreshStatus()
        }
      }
    }
  }

  Process {
    id: probeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.probing = false
        var parsed = Model.parseJsonLine(text)
        root.probeResult = parsed || { ok: false, error: "No response from helper" }
      }
    }
  }

  Process {
    id: activityProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var clientId = root.pendingActivityClientId
        root.pendingActivityClientId = ""
        if (!clientId) return
        var parsed = Model.parseJsonLine(text)
        // A failed poll (offline client, bad creds, ...) counts as no
        // activity from that client rather than being left stale forever.
        var totals = (parsed && parsed.ok) ? (parsed.totals || { down: 0, up: 0 }) : { down: 0, up: 0 }
        var updated = {}
        for (var id in root.clientActivity) updated[id] = root.clientActivity[id]
        updated[clientId] = totals
        root.clientActivity = updated
      }
    }
  }

  // The only process here that isn't helper.py: Omarchy's shared native
  // file-picker portal, filtered to .torrent files. Prints the chosen path
  // (or nothing, if cancelled) to stdout.
  Process {
    id: filePickProc
    command: ["omarchy-file-select", "--title", "Add torrent file", "--extensions", "torrent"]
    stdout: StdioCollector { id: filePickStdout; waitForEnd: true }
    stderr: StdioCollector { id: filePickStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var path = filePickStdout.text.trim()
      if (path !== "") root.addTorrentFile(path)
    }
  }

  Timer {
    id: actionMessageTimer
    interval: 4000
    repeat: false
    onTriggered: root.actionMessage = ""
  }
}
