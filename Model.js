.pragma library

// Pure formatting/sorting helpers shared by Panel.qml and Service.qml.
// Deliberately has no Quickshell/QML dependencies (plain JS only), so it can
// also be loaded and unit-tested standalone under plain Node.

var KIND_LABELS = {
  transmission: "Transmission",
  qbittorrent: "qBittorrent",
  deluge: "Deluge"
}

var ACTIVITY_LABELS = {
  idle: "Idle",
  seeding: "Seeding",
  downloading: "Downloading"
}

function activityLabel(status) {
  return ACTIVITY_LABELS[status] || ACTIVITY_LABELS.idle
}

var STATUS_LABELS = {
  downloading: { text: "Downloading", role: "accent" },
  seeding: { text: "Seeding", role: "foreground" },
  paused: { text: "Paused", role: "muted" },
  queued: { text: "Queued", role: "muted" },
  checking: { text: "Checking", role: "foreground" },
  error: { text: "Error", role: "urgent" },
  finished: { text: "Finished", role: "foreground" },
  unknown: { text: "Unknown", role: "muted" }
}

function kindLabel(kind) {
  return KIND_LABELS[kind] || String(kind || "")
}

function statusInfo(status) {
  return STATUS_LABELS[status] || STATUS_LABELS.unknown
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024
    index++
  }
  var decimals = index === 0 ? 0 : (value >= 100 ? 0 : (value >= 10 ? 1 : 2))
  return value.toFixed(decimals) + " " + units[index]
}

function formatSpeed(bytesPerSec) {
  var value = Number(bytesPerSec || 0)
  return value > 0 ? formatBytes(value) + "/s" : "—"
}

function formatEta(seconds) {
  var s = Number(seconds)
  if (!isFinite(s) || s < 0) return "—"
  s = Math.floor(s)
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  if (h > 0) return h + "h" + (m < 10 ? "0" : "") + m + "m"
  if (m > 0) return m + "m" + (sec < 10 ? "0" : "") + sec + "s"
  return sec + "s"
}

function formatRatio(ratio) {
  var r = Number(ratio || 0)
  return r.toFixed(2)
}

function formatPercent(progress) {
  var p = Number(progress || 0)
  return Math.round(Math.max(0, Math.min(1, p)) * 100) + "%"
}

function torrentName(t) {
  return String(t && t.name || "").toLowerCase()
}

// Fixed default order: downloading torrents float to the top, paused
// torrents sink to the bottom, everything else (dominated by seeding) sits
// in between. Alphabetical by name within each of the three groups.
function sortGroup(status) {
  if (status === "downloading") return 0
  if (status === "paused") return 2
  return 1
}

function sortTorrents(torrents) {
  return torrents.slice().sort(function(a, b) {
    var ga = sortGroup(a.status)
    var gb = sortGroup(b.status)
    if (ga !== gb) return ga - gb
    return torrentName(a).localeCompare(torrentName(b))
  })
}

function parseJsonLine(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null
  // A helper invocation only ever emits one JSON object per line; if a
  // caller's stdout somehow gets multiple lines, the last one wins.
  var lines = text.split("\n")
  var lastLine = lines[lines.length - 1]
  try {
    return JSON.parse(lastLine)
  } catch (e) {
    return null
  }
}
