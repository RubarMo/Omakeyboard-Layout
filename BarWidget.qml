import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "LayoutModel.js" as LayoutModel

// Windows/macOS-style language switcher: native pill, click-to-pick panel,
// right-click and scroll to cycle, optional per-window memory.
BarWidget {
  id: root
  moduleName: "rubar.omakeyboard-layout"

  // ---- seat reading (ported from the stock widget) -------------------------
  property string layoutFull: ""
  property string keyboardName: ""
  property string typedKeyboardName: ""
  property bool keyboardUnresolved: false
  property bool multipleLayouts: true
  property int layoutIndex: 0
  property int layoutCount: 0
  property var layoutCodes: []
  property string layoutVariants: ""
  property var layoutBriefs: ({})
  property var layoutDescriptions: ({})
  property bool layoutsRead: false
  property bool briefsRequested: false
  readonly property bool needsBriefs: layoutsRead && (multipleLayouts || multipleInputs)
  onNeedsBriefsChanged: loadBriefs()

  function loadBriefs() {
    if (!needsBriefs || briefsRequested) return
    briefsRequested = true
    briefsProc.running = true
  }

  readonly property var table: ({ briefs: layoutBriefs, descriptions: layoutDescriptions })
  readonly property var entries: LayoutModel.layoutEntries(layoutCodes.join(","), layoutVariants, table)
  readonly property var activeEntry: entries.length > 0 ? entries[Math.min(layoutIndex, entries.length - 1)] : null
  readonly property string layoutLabel: activeEntry ? activeEntry.pill : LayoutModel.shortLabel(layoutFull, layoutBriefs)

  readonly property var inputState: InputMethodState.state
  readonly property bool multipleInputs: (inputState.methods || []).length > 1
  readonly property string inputLabel: LayoutModel.inputLabel(inputState, layoutLabel)

  // ---- user preferences (shell.json inline, persisted via updateEntryInline)
  readonly property bool rememberWindows: setting("rememberWindows", false)

  readonly property string pillText: {
    if (!activeEntry) return inputLabel
    // Always the Latin brief (DE / AR): readable at a glance in the bar.
    return inputState.current && inputState.current.indexOf("keyboard-") !== 0 ? inputLabel : activeEntry.label
  }

  function persistSettings(values) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: "rubar.omakeyboard-layout" }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var k in values) entry[k] = values[k]
    // Optimistic local apply so the switch flips on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    root.bar.shell.updateEntryInline("rubar.omakeyboard-layout", entry)
  }

  // ---- MRU: jump back to the last layout instead of stepping forward --------
  property var recentLayouts: []

  // ---- per-window memory ------------------------------------------------------
  // windowKey -> layout index. Persisted to a state file so it survives shell
  // restarts. Debounced on focus so Alt-Tab bursts don't thrash.
  property var windowMemory: ({})
  property string memoryPath: Quickshell.env("HOME") + "/.local/state/omarchy/omakeyboard-layout.json"
  property string pendingWindowKey: ""
  property string pendingWindowApp: ""

  function memoryKeyFor(toplevel) {
    if (!toplevel) return ""
    var addr = ""
    try {
      if (toplevel.address) addr = String(toplevel.address)
      else if (toplevel.wayland && toplevel.wayland.address) addr = String(toplevel.wayland.address)
    } catch (e) {}
    if (addr !== "") return "addr:" + addr
    try {
      if (toplevel.appId) return "app:" + String(toplevel.appId)
      if (toplevel.wayland && toplevel.wayland.appId) return "app:" + String(toplevel.wayland.appId)
    } catch (e2) {}
    return ""
  }

  function appIdFor(toplevel) {
    try {
      if (toplevel) {
        if (toplevel.appId) return String(toplevel.appId)
        if (toplevel.wayland && toplevel.wayland.appId) return String(toplevel.wayland.appId)
      }
    } catch (e) {}
    return ""
  }

  function loadMemory(raw) {
    try {
      var parsed = JSON.parse(raw || "{}")
      if (parsed && typeof parsed === "object") root.windowMemory = parsed
    } catch (e) {}
  }

  function saveMemory() {
    memoryFile.setText(JSON.stringify(root.windowMemory) + "\n")
  }

  function noteLayoutForWindow(key, index) {
    if (!rememberWindows || !key || index < 0 || index >= layoutCount) return
    var next = {}
    for (var k in root.windowMemory) next[k] = root.windowMemory[k]
    next[key] = index
    // Bound the map: forget the oldest entries past 200 windows.
    var keys = Object.keys(next)
    if (keys.length > 200) {
      for (var i = 0; i < keys.length - 200; i++) delete next[keys[i]]
    }
    root.windowMemory = next
    memorySaveTimer.restart()
  }

  function onFocusChanged() {
    if (!rememberWindows || layoutCount < 2) return
    var toplevel = null
    try { toplevel = ToplevelManager.activeToplevel } catch (e) {}
    var key = root.memoryKeyFor(toplevel)
    var app = root.appIdFor(toplevel)
    if (key === "") return
    // Same window still focused: nothing to do.
    if (key === root.pendingWindowKey) return
    root.pendingWindowKey = key
    root.pendingWindowApp = app
    focusDebounce.restart()
  }

  function applyPendingFocus() {
    var key = root.pendingWindowKey
    if (!rememberWindows || key === "") return
    var wanted = root.windowMemory[key]
    // Fall back to the app-level default when this exact window is new.
    if (wanted === undefined && root.pendingWindowApp !== "") wanted = root.windowMemory["app:" + root.pendingWindowApp]
    if (wanted === undefined || wanted === layoutIndex) return
    if (wanted < 0 || wanted >= layoutCount) return
    // Don't fight the user mid-switch: only auto-apply when the seat has been
    // quiet for the debounce window.
    setLayout(wanted, "memory")
  }

  // ---- switching ---------------------------------------------------------------
  // Device names are attacker-controlled: a USB keyboard can choose its own name,
  // and hyprctl interprets names that start with "-" as options (including
  // --batch). Hyprland treats "all"/"main"/"active"/"current" as special targets
  // too. So never interpolate a device name into the switch: "all" is a constant
  // Hyprland target and the index is forced to an integer here. The argv call also
  // avoids a shell entirely.
  function runSwitch(index) {
    if (layoutCount < 2) return
    var target = Math.floor(Number(index))
    if (!isFinite(target) || target < 0 || target >= layoutCount) return
    Quickshell.execDetached(["hyprctl", "switchxkblayout", "all", String(target)])
    refreshTimer.restart()
  }

  function noteLayoutHere(index) {
    if (!rememberWindows || index < 0 || index >= layoutCount) return
    var toplevel = null
    try { toplevel = ToplevelManager.activeToplevel } catch (e) {}
    var key = root.memoryKeyFor(toplevel)
    if (key === "") return
    noteLayoutForWindow(key, index)
    var app = root.appIdFor(toplevel)
    if (app !== "") noteLayoutForWindow("app:" + app, index)
  }

  function setLayout(index, why) {
    index = Math.floor(Number(index))
    if (!isFinite(index) || index < 0 || index >= layoutCount) return
    if (index === layoutIndex && why !== "panel") {
      // Already there; still record MRU freshness.
      recentLayouts = LayoutModel.pushRecent(recentLayouts, index, layoutCount)
      return
    }
    recentLayouts = LayoutModel.pushRecent(recentLayouts, index, layoutCount)
    flashOsd(index)
    // Per-window memory learns the *manual* choice; memory-driven restores
    // don't rewrite themselves.
    if (why === "manual" || why === "panel") root.noteLayoutHere(index)
    runSwitch(index)
  }

  function cycleForward() {
    if (layoutCount < 2) return
    setLayout((layoutIndex + 1) % layoutCount, "manual")
  }

  function cycleBackward() {
    if (layoutCount < 2) return
    setLayout((layoutIndex + layoutCount - 1) % layoutCount, "manual")
  }

  function mruSwitch() {
    if (layoutCount < 3) {
      cycleForward()
      return
    }
    setLayout(LayoutModel.mruTarget(recentLayouts, layoutIndex, layoutCount), "manual")
  }

  // ---- OSD flash on switches (always on) ------------------------------------------
  // External switches (Shift+Alt) bypass setLayout: the seat reading below
  // flashes those, keyed on lastFlashedIndex so our own switches (flashed
  // optimistically in setLayout) don't toast twice.
  property int lastFlashedIndex: -1
  // Becomes true after the first seat reading; guards the startup read from
  // toasting.
  property bool seatSettled: false

  function flashOsd(index) {
    var list = root.entries
    if (index < 0 || index >= list.length) return
    var entry = list[index]
    var label = entry.nativeName !== "" ? entry.nativeName + " · " + entry.label : entry.description
    if (!root.bar || typeof root.bar.run !== "function") return
    root.lastFlashedIndex = index
    root.bar.run("omarchy-shell -q osd show " + Util.shellQuote(JSON.stringify({
      icon: "keyboard", message: label, duration: 900
    })))
  }

  // ---- layout add/remove ---------------------------------------------------------
  // The seat's list lives in ~/.config/hypr/input.lua (kb_layout/kb_variant);
  // a helper script rewrites those lines and reloads Hyprland live.
  readonly property string applyScript: Quickshell.env("HOME") + "/.config/omarchy/plugins/rubar.omakeyboard-layout/layouts-apply.py"
  property string catalogError: ""
  property bool searching: false
  property string searchQuery: ""
  property int searchIndex: 0
  // The search field lives inside the panel's lazy content, whose ids are not
  // visible from root scope; the field registers itself here on completion.
  property var searchFieldItem: null
  property bool searchHasFocus: false

  readonly property var catalogRows: LayoutModel.catalogEntries(table)
  readonly property var addedKeys: layoutCodes.map(function (code, i) {
    var variants = layoutVariants.split(",")
    return code + ":" + (variants[i] || "")
  })
  readonly property var searchHits: LayoutModel.searchCatalog(catalogRows, searchQuery, 6, searching ? addedKeys : [])

  function openSearch() {
    searching = true
    searchQuery = ""
    searchIndex = 0
    catalogError = ""
    rowIndex = panelRows.indexOf("add")
    cursorActive = true
  }

  function closeSearch() {
    searching = false
    searchQuery = ""
    searchIndex = 0
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function moveSearch(dy) {
    if (searchHits.length === 0) return
    searchIndex = Math.max(0, Math.min(searchHits.length - 1, searchIndex + dy))
  }

  function pickSearch() {
    if (searchIndex < 0 || searchIndex >= searchHits.length) return
    var hit = searchHits[searchIndex]
    applyLayouts("add", hit.code, hit.variant)
  }

  function currentList() {
    var codes = layoutCodes.slice()
    var variants = layoutVariants.split(",")
    while (variants.length < codes.length) variants.push("")
    var items = []
    for (var i = 0; i < codes.length; i++) {
      if (codes[i]) items.push({ code: codes[i], variant: variants[i] || "" })
    }
    return LayoutModel.parseLayoutList(
      items.map(function (it) { return it.code }).join(","),
      items.map(function (it) { return it.variant }).join(",")
    ) || []
  }

  function applyLayouts(mode, code, variant, index) {
    var items = root.currentList()
    var next = mode === "add"
      ? LayoutModel.addLayoutItem(items, code, variant)
      : LayoutModel.removeLayoutItem(items, index)
    if (!next) {
      catalogError = mode === "add"
        ? strings.t("panel.addDuplicate")
        : strings.t("panel.removeBlocked")
      return
    }
    var ser = LayoutModel.serializeLayoutList(next)
    catalogError = ""
    applyProc.command = ["python3", root.applyScript, "set", ser.layouts, ser.variants]
    applyProc.running = true
  }

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyOut; waitForEnd: true }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) {
        root.catalogError = String(applyErr.text || "").replace(/^omakeyboard-layout:\s*/, "").trim()
          || strings.t("panel.applyFailed")
        return
      }
      root.catalogError = ""
      root.closeSearch()
      root.refresh()
      refreshTimer.restart()
    }
  }

  // ---- panel state ---------------------------------------------------------
  property int rowIndex: 0
  property bool cursorActive: false

  readonly property var panelRows: {
    var rows = []
    for (var i = 0; i < entries.length; i++) rows.push("layout:" + i)
    rows.push("add")
    rows.push("sep")
    rows.push("memory")
    return rows
  }

  function moveCursor(dy) {
    if (searching) {
      root.moveSearch(dy)
      return
    }
    cursorActive = true
    var rows = root.panelRows
    var next = rowIndex + dy
    // Skip the separator.
    if (next >= 0 && next < rows.length && rows[next] === "sep") next += dy > 0 ? 1 : -1
    rowIndex = Math.max(0, Math.min(rows.length - 1, next))
  }

  function activateCursor() {
    if (searching) {
      root.pickSearch()
      return
    }
    var rows = root.panelRows
    var row = rows[Math.min(rowIndex, rows.length - 1)]
    if (!row || row === "sep") return
    if (row.indexOf("layout:") === 0) {
      setLayout(parseInt(row.slice(7), 10), "panel")
      root.close()
      return
    }
    if (row === "add") {
      root.openSearch()
      return
    }
    if (row === "memory") {
      persistSettings({ rememberWindows: !rememberWindows })
      return
    }
  }

  function rowLabelFor(i) {
    var rows = root.panelRows
    return rows[Math.min(i, rows.length - 1)]
  }

  function openPanel() {
    rowIndex = Math.max(0, Math.min(layoutIndex, entries.length - 1))
    cursorActive = false
    searching = false
    searchQuery = ""
    catalogError = ""
    root.open()
  }

  function togglePanel() {
    if (root.opened) root.close()
    else root.openPanel()
  }

  onOpenedChanged: {
    if (opened) {
      rowIndex = Math.max(0, Math.min(layoutIndex, entries.length - 1))
      cursorActive = false
      Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    }
  }

  // Panel owns the open/close lifecycle; shared via the Panel base.
  Panel {
    id: panelHost
  }

  property alias opened: panelHost.controller.open

  function open() { panelHost.open() }
  function close() { panelHost.close() }
  function toggle() { root.togglePanel() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function") return root.bar.switchPanelFrom(root, direction)
    return false
  }

  readonly property color barForeground: bar ? bar.barForeground : Commons.Color.foreground

  ShellIpc {
    target: "rubar.omakeyboard-layout"
    function toggle(): void { root.togglePanel() }
    function open(): void { root.openPanel() }
    function close(): void { root.close() }
    function cycle(): void { root.cycleForward() }
    function back(): void { root.cycleBackward() }
    function mru(): void { root.mruSwitch() }
    function state(): string {
      return JSON.stringify({
        index: root.layoutIndex, count: root.layoutCount,
        pill: root.pillText, full: root.layoutFull,
        searching: root.searching,
        bar: root.bar !== null, visible: root.visible,
        unresolved: root.keyboardUnresolved, layoutsRead: root.layoutsRead,
        kbName: root.keyboardName, querying: queryProc.running,
        remember: root.rememberWindows
      })
    }
  }

  // ---- seat reading processes (ported from the stock widget) -------------------
  property bool refreshPending: false

  function refresh() {
    if (queryProc.running) {
      refreshPending = true
      return
    }
    refreshPending = false
    queryProc.running = true
  }

  function typedKeyboards(keyboards) {
    return keyboards.filter(function (k) { return LayoutModel.isTypedKeyboard(k.name) })
  }

  function selectKeyboard(typed) {
    return LayoutModel.selectKeyboard(typed, root.typedKeyboardName)
  }

  Component.onCompleted: refresh()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name === "activelayout") {
        const named = LayoutModel.eventKeyboardName(event)
        if (named) root.typedKeyboardName = named
      }
      if (name.indexOf("activelayout") !== -1 || name === "configreloaded") root.refresh()
      // Focus changes drive per-window memory (debounced).
      if (name === "activewindowv2" || name === "activewindow" || name === "workspacev2") root.onFocusChanged()
    }
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { root.onFocusChanged() }
  }

  Process {
    id: queryProc
    command: ["hyprctl", "-j", "devices"]
    onRunningChanged: {
      if (running) {
        stallTimer.restart()
        return
      }
      stallTimer.stop()
      if (root.refreshPending) root.refresh()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let listed
        try {
          listed = JSON.parse(text || "{}").keyboards
        } catch (e) {
          root.keyboardUnresolved = true
          return
        }
        if (!Array.isArray(listed)) {
          root.keyboardUnresolved = true
          return
        }
        const typed = root.typedKeyboards(listed)
        const kb = root.selectKeyboard(typed)
        if (!kb || !kb.active_keymap) {
          root.keyboardUnresolved = true
          if (typed.length === 0) {
            root.layoutFull = ""
            root.keyboardName = ""
          }
          return
        }

        var prevIndex = root.layoutIndex
        root.keyboardUnresolved = false
        root.keyboardName = String(kb.name || "")
        root.multipleLayouts = kb.layout === undefined || String(kb.layout).indexOf(",") !== -1
        root.layoutsRead = true
        root.layoutCodes = String(kb.layout || "").split(",")
        root.layoutVariants = String(kb.variant === undefined || kb.variant === null ? "" : kb.variant)
        root.layoutIndex = kb.active_layout_index || 0
        root.layoutCount = kb.layout === undefined ? 0 : root.layoutCodes.length
        root.layoutFull = kb.active_keymap
        if (prevIndex !== root.layoutIndex) {
          recentLayouts = LayoutModel.pushRecent(recentLayouts, root.layoutIndex, Math.max(1, root.layoutCount))
          // A change the widget didn't initiate came from outside (Shift+Alt,
          // another tool): learn it for per-window memory and toast it, unless
          // this reading just confirms our own optimistic flash. The very
          // first reading only establishes the seat.
          if (root.seatSettled && root.layoutIndex !== root.lastFlashedIndex) {
            root.noteLayoutHere(root.layoutIndex)
            root.flashOsd(root.layoutIndex)
          }
          root.seatSettled = true
        }
      }
    }
  }

  Process {
    id: briefsProc
    command: ["xkbcli", "list", "--load-exotic"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var table = LayoutModel.layoutTable(text)
        root.layoutBriefs = table.briefs
        root.layoutDescriptions = table.descriptions
      }
    }
  }

  // Per-window memory lives in a state file, not shell.json: window addresses
  // churn constantly and would dirty the user config on every focus change.
  FileView {
    id: memoryFile
    path: root.memoryPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadMemory(text())
    onLoadFailed: root.loadMemory("{}")
  }

  Timer {
    id: memorySaveTimer
    interval: 1500
    onTriggered: root.saveMemory()
  }

  Timer {
    id: focusDebounce
    interval: 250
    onTriggered: root.applyPendingFocus()
  }

  Timer {
    id: refreshTimer
    interval: 600
    onTriggered: root.refresh()
  }

  Timer {
    id: stallTimer
    interval: 5000
    onTriggered: {
      queryProc.running = false
      refreshTimer.restart()
    }
  }

  Connections {
    target: InputDevices
    function onChanged() { root.refresh() }
  }

  Timer {
    interval: 10000
    running: !root.keyboardName || root.keyboardUnresolved || !InputDevices.healthy
    repeat: true
    onTriggered: root.refresh()
  }

  visible: inputLabel !== "" && LayoutModel.showIndicator(layoutLabel, multipleLayouts, multipleInputs)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pillText
    fontSize: Style.font.caption
    horizontalMargin: 6
    tooltipText: LayoutModel.inputTooltip(root.inputState, root.layoutFull, root.multipleLayouts)
    onPressed: function (code) {
      if (code === Qt.RightButton || code === Qt.MiddleButton) root.cycleForward()
      else root.togglePanel()
    }
    onWheelMoved: function (delta) {
      if (delta > 0) root.cycleBackward()
      else root.cycleForward()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      blocked: root.searchHasFocus
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: {
        if (root.searching) root.closeSearch()
        else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (root.searching) return
        var key = String(t || "").toLowerCase()
        // 1..9 jump straight to a layout.
        var n = parseInt(key, 10)
        if (n >= 1 && n <= root.entries.length) {
          root.rowIndex = n - 1
          root.cursorActive = true
          root.activateCursor()
        }
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: strings.t("panel.title")
          meta: root.layoutFull !== "" ? root.layoutFull.toUpperCase() : ""
          detail: root.pillText
          foreground: bar ? bar.foreground : Commons.Color.foreground
          fontFamily: bar ? bar.fontFamily : Style.font.family
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: "󰌌"
              color: bar ? bar.foreground : Commons.Color.foreground
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.entries
            LayoutRow {
              required property var modelData
              required property int index
              width: column.width
              rowLabel: modelData.description
              nativeLabel: modelData.nativeName
              pill: modelData.label
              hint: String(index + 1)
              selected: root.layoutIndex === modelData.index
              rowCursor: root.cursorActive && !root.searching && root.rowIndex === index
              rowDim: root.dim
              removable: root.searching
              onPicked: {
                root.rowIndex = index
                root.setLayout(modelData.index, "panel")
                root.close()
              }
              onHovered: root.rowIndex = index
              onRemove: root.applyLayouts("remove", "", "", modelData.index)
            }
          }

          // Add-a-layout: a row that expands into a live-filtered catalog.
          CursorSurface {
            width: column.width
            hasCursor: root.cursorActive && root.rowLabelFor(root.rowIndex) === "add"
            foreground: bar ? bar.foreground : Commons.Color.foreground
            implicitHeight: addContent.implicitHeight + Style.spacing.rowPaddingX
            visible: !root.searching

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: {
                root.cursorActive = true
                root.rowIndex = root.panelRows.indexOf("add")
              }
              onClicked: root.openSearch()
            }

            RowLayout {
              id: addContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "+"
                color: bar ? bar.foreground : Commons.Color.foreground
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                Layout.alignment: Qt.AlignVCenter
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: strings.t("panel.add")
                color: bar ? bar.foreground : Commons.Color.foreground
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.searching

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: strings.t("panel.searchPlaceholder")
                foreground: bar ? bar.foreground : Commons.Color.foreground
                font.family: bar ? bar.fontFamily : Style.font.family
                text: root.searchQuery
                // Declarative focus: follows add-mode instead of racing the
                // surface's focus prime with an imperative call.
                focus: root.searching
                onTextChanged: {
                  root.searchQuery = text
                  root.searchIndex = 0
                }
                onActiveFocusChanged: root.searchHasFocus = activeFocus
                Component.onCompleted: root.searchFieldItem = searchField
                Keys.onEscapePressed: root.closeSearch()
                Keys.onReturnPressed: root.pickSearch()
                Keys.onEnterPressed: root.pickSearch()
                Keys.onUpPressed: root.moveSearch(-1)
                Keys.onDownPressed: root.moveSearch(1)
              }

              PanelActionButton {
                iconText: ""
                tooltipText: strings.t("panel.cancelAdd")
                foreground: bar ? bar.foreground : Commons.Color.foreground
                fontFamily: bar ? bar.fontFamily : Style.font.family
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.closeSearch()
              }
            }

            Text {
              width: parent.width
              visible: root.catalogError !== ""
              textFormat: Text.PlainText
              text: root.catalogError
              color: Commons.Color.urgent
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: root.searchQuery !== "" && root.searchHits.length === 0 && root.catalogError === ""
              textFormat: Text.PlainText
              text: strings.t("panel.noResults")
              color: root.dim
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.searchHits
              LayoutRow {
                required property var modelData
                required property int index
                width: column.width
                rowLabel: modelData.description + (modelData.variant !== "" ? "  ·  " + modelData.variant : "")
                nativeLabel: modelData.native !== modelData.description ? modelData.native : ""
                pill: modelData.label + (root.addedKeys.indexOf(modelData.code + ":" + modelData.variant) !== -1 ? " ✓" : "")
                hint: ""
                selected: false
                rowCursor: root.searchIndex === index
                rowDim: root.dim
                removable: false
                onPicked: {
                  root.searchIndex = index
                  root.pickSearch()
                }
                onHovered: root.searchIndex = index
              }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.bar ? root.bar.foreground : Commons.Color.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          ToggleRow {
            width: parent.width
            rowTitle: strings.t("panel.memory")
            rowCaption: strings.t("panel.memoryCaption")
            rowChecked: root.rememberWindows
            rowCursor: root.cursorActive && root.rowLabelFor(root.rowIndex) === "memory"
            onPicked: persistSettings({ rememberWindows: !rememberWindows })
            onHovered: function (on) {
              if (on) {
                root.cursorActive = true
                root.rowIndex = root.panelRows.indexOf("memory")
              }
            }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("panel.footer")
          color: Qt.darker(bar ? bar.foreground : Commons.Color.foreground, 1.55)
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  readonly property color dim: Qt.darker(bar ? bar.foreground : Commons.Color.foreground, 1.55)

  // Compact labeled switch row. Same construction as the kit's Toggle (plain
  // Row with anchored vertical centering, never a RowLayout cell) so the
  // knob lands on the same pixels as every stock panel; only the 54px
  // min-height is dropped for a denser panel.
  component ToggleRow: CursorSurface {
    id: toggleRow
    property string rowTitle: ""
    property string rowCaption: ""
    property bool rowChecked: false
    property bool rowCursor: false

    signal picked()
    signal hovered(bool isHovered)

    hasCursor: rowCursor
    foreground: bar ? bar.foreground : Commons.Color.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    Row {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: toggleRow.borderLeft + Style.spacing.rowPaddingX
      anchors.rightMargin: toggleRow.borderRight + Style.spacing.rowPaddingX
      spacing: Style.spacing.rowPaddingX

      Column {
        width: parent.width - track.width - parent.spacing
        spacing: Style.spacing.xs
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: toggleRow.rowTitle
          color: bar ? bar.foreground : Commons.Color.foreground
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: text !== ""
          text: toggleRow.rowCaption
          color: Qt.darker(bar ? bar.foreground : Commons.Color.foreground, 1.5)
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      ToggleSwitch {
        id: track
        checked: toggleRow.rowChecked
        foreground: bar ? bar.foreground : Commons.Color.foreground
        accent: Commons.Color.accent
        interactive: false
        // 28/20/4 divides evenly at 1.0/1.25/1.5/1.75/2.0 scales, so the knob
        // stays pixel-centered everywhere; the default 22/16/3 leaves a 1px
        // bias at fractional scales depending on screen phase.
        trackHeight: 28
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: toggleRow.hovered(containsMouse)
      onClicked: toggleRow.picked()
    }
  }

  component LayoutRow: CursorSurface {
    id: layoutRow
    property string rowLabel: ""
    property string nativeLabel: ""
    property string pill: ""
    property string hint: ""
    property bool selected: false
    property bool rowCursor: false
    property bool removable: false
    property color rowDim: Commons.Color.foreground

    signal picked()
    signal hovered()
    signal remove()

    hasCursor: rowCursor
    current: selected
    foreground: bar ? bar.foreground : Commons.Color.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: parent.hovered()
      onClicked: parent.picked()
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        Layout.preferredWidth: Style.space(14)
        text: layoutRow.selected ? "" : ""
        color: bar ? bar.foreground : Commons.Color.foreground
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: layoutRow.rowLabel
          color: bar ? bar.foreground : Commons.Color.foreground
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: layoutRow.selected
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: text !== ""
          text: layoutRow.nativeLabel !== layoutRow.rowLabel ? layoutRow.nativeLabel : ""
          color: layoutRow.rowDim
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        text: layoutRow.pill
        color: layoutRow.rowDim
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        visible: layoutRow.hint !== ""
        text: layoutRow.hint
        color: layoutRow.rowDim
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      PanelActionButton {
        visible: layoutRow.removable
        iconText: ""
        tooltipText: strings.t("panel.remove")
        foreground: bar ? bar.foreground : Commons.Color.foreground
        fontFamily: bar ? bar.fontFamily : Style.font.family
        Layout.alignment: Qt.AlignVCenter
        onClicked: layoutRow.remove()
      }
    }
  }

}
