// Pure layout math for the keyboard switcher, kept Qt-free so it can be unit
// tested under node.

var NON_LATIN = "af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm mn np rs ru sy th tj ua".split(" ")

function isNonLatin(layoutCode) {
  return NON_LATIN.indexOf(String(layoutCode || "").toLowerCase()) !== -1
}

// xkbcli list prints YAML, and every layout and variant block pairs a brief with
// the description hyprctl reports as the active keymap:
//
//   - layout: 'us'
//     variant: ''
//     brief: 'en'
//     description: English (US)
//
// Keyed by "layout:variant" so a variant description (e.g. Arabic (AZERTY))
// resolves instead of falling back to the base layout's.
function layoutTable(text) {
  var briefs = {}
  var descriptions = {}
  var brief = ""
  var layout = ""
  var variant = ""

  String(text || "").split("\n").forEach(function (line) {
    if (/^\s*- /.test(line)) {
      brief = ""
      layout = ""
      variant = ""
    }

    var entry = line.match(/^(?:- |  )(layout|variant|brief|description): (.*)$/)
    if (!entry) return

    var value = entry[2].replace(/^'|'$/g, "")
    if (entry[1] === "layout") layout = value
    else if (entry[1] === "variant") variant = value
    else if (entry[1] === "brief") brief = value
    else if (brief && layout) {
      briefs[entry[2]] = brief
      descriptions[layout + ":" + variant] = entry[2]
      brief = ""
    }
  })

  return { briefs: briefs, descriptions: descriptions }
}

// Backwards-compatible brief-only view (same shape as the stock model's
// layoutBriefs).
function layoutBriefs(text) {
  return layoutTable(text).briefs
}

function descriptionFor(code, variant, table) {
  var hit = (table.descriptions || {})[code + ":" + (variant || "")]
  if (typeof hit === "string" && hit) return hit
  var base = (table.descriptions || {})[code + ":"]
  if (typeof base === "string" && base) return base
  return ""
}

// The brief is a short language code rather than a country one, which keeps the
// label sensible for the layouts named after a language: Esperanto reads EO and
// Arabic reads AR. It is the same code GNOME shows in its own indicator.
function shortLabel(description, briefs) {
  if (!description) return ""

  var brief = (briefs || {})[description]
  var label = typeof brief === "string" && brief ? brief.split("-")[0] : description.split(/\s+/)[0]
  return label.substring(0, 3).toUpperCase()
}

// Native pill shorts for scripts where the latin brief is not what a typist
// looks for. Everything else falls back to the upper-cased brief.
var NATIVE_SHORTS = {
  ar: "ع", he: "ע", fa: "ف", ur: "ا", am: "አ", th: "ท", lo: "ລ", km: "ខ",
  yi: "י", kn: "ಕ", ml: "മ", ta: "த", te: "తె", hi: "हिं", bn: "বাং", gu: "ગુ",
  pa: "ਪੰ", or: "ଓ", si: "සිං", my: "မြ", zh: "拼", ja: "あ", ko: "한"
}

function nativeShort(brief) {
  var code = String(brief || "").split("-")[0].toLowerCase()
  if (NATIVE_SHORTS[code]) return NATIVE_SHORTS[code]
  if (!code) return ""
  return code.substring(0, 3).toUpperCase()
}

// Full native names for the panel list, so العربية reads as العربية and not
// "Arabic". Falls back to the xkb description for anything unlisted.
var NATIVE_NAMES = {
  "German": "Deutsch",
  "Arabic": "العربية",
  "Arabic (AZERTY)": "العربية",
  "Arabic (Eastern Arabic numerals)": "العربية",
  "French": "Français",
  "French (Canada)": "Français",
  "Spanish": "Español",
  "Russian": "Русский",
  "Hebrew": "עברית",
  "Greek": "Ελληνικά",
  "Italian": "Italiano",
  "Dutch": "Nederlands",
  "Polish": "Polski",
  "Turkish": "Türkçe",
  "Ukrainian": "Українська",
  "Persian": "فارسی",
  "Hindi": "हिन्दी",
  "Chinese": "中文",
  "Japanese": "日本語",
  "Korean": "한국어",
  "Portuguese": "Português",
  "Czech": "Čeština",
  "Swedish": "Svenska",
  "Danish": "Dansk",
  "Norwegian": "Norsk",
  "Finnish": "Suomi"
}

function nativeName(description) {
  var hit = NATIVE_NAMES[String(description || "")]
  return typeof hit === "string" && hit ? hit : String(description || "")
}

// One row per layout in kb.layout, resolved against the xkb table.
function layoutEntries(layoutCsv, variantCsv, table) {
  var codes = String(layoutCsv || "").split(",")
  var variants = String(variantCsv === undefined || variantCsv === null ? "" : variantCsv).split(",")
  var out = []
  for (var i = 0; i < codes.length; i++) {
    if (!codes[i]) continue
    var description = descriptionFor(codes[i], variants[i] || "", table) || codes[i]
    var label = shortLabel(description, table.briefs)
    var brief = (table.briefs || {})[description]
    var native = typeof brief === "string" && brief ? nativeShort(brief) : ""
    out.push({
      index: out.length,
      code: codes[i],
      variant: variants[i] || "",
      description: description,
      label: label,
      pill: native !== "" ? native : label,
      native: native,
      nativeName: nativeName(description),
      nonLatin: isNonLatin(codes[i])
    })
  }
  return out
}

// Most-recently-used target: the freshest index that is not the current one.
// With two layouts this is just the other one; with three or more it jumps
// back to whatever was used last instead of stepping blindly forward.
function mruTarget(recent, current, count) {
  for (var i = recent.length - 1; i >= 0; i--) {
    var idx = recent[i]
    if (idx !== current && idx >= 0 && idx < count) return idx
  }
  return (current + 1) % Math.max(1, count)
}

function pushRecent(recent, index, count) {
  var kept = (recent || []).filter(function (i) { return i !== index })
  kept.push(index)
  while (kept.length > count) kept.shift()
  return kept
}

// Hyprland's activelayout event pairs the keyboard that switched with the layout
// it moved to. Quickshell cuts the event into that many fields, so a description
// carrying a comma of its own stays in one piece; a binding old enough to hand
// back only the raw string gets split by hand. The virtual keyboard fcitx5 binds
// to inject announces switches too, and names a keyboard nobody types on.
function eventKeyboardName(event) {
  var parts

  try {
    if (event && event.parse) parts = event.parse(2)
  } catch (error) {
  }

  if (!parts) parts = String(event && event.data ? event.data : "").split(",")

  var name = String(parts[0] || "")
  return isTypedKeyboard(name) ? name : ""
}

// Hyprland reports more than keyboards as keyboards. fcitx5 binds a virtual one
// to inject through, which keeps the us layout the input method gave it, and the
// ACPI power button, lid switch and sleep key each arrive carrying the seat's
// layout list without anyone ever typing on them. Both answer to switchxkblayout
// and both can hold the main flag, so a widget that reads or switches whatever
// the seat hands it ends up describing a button. Leave them out and what remains
// is keyboards, which is what the rest of this file can then assume.
//
// Missing a name here costs the accuracy the seat had before, never a keyboard:
// anything unrecognised stays in the list.
var UNTYPED_KEYBOARDS = /^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)|(-wmi-hotkeys|-wireless-radio-control)(-\d+)?$/

function isTypedKeyboard(name) {
  return !UNTYPED_KEYBOARDS.test(String(name || ""))
}

// Every keyboard on the seat carries the same layout list unless one was given
// its own, but only the one being typed on advances through it. So the
// furthest-advanced is the one worth reading, and a switch names the keyboard it
// moved, which settles a seat holding two real keyboards outright.
function selectKeyboard(keyboards, namedByEvent) {
  var list = keyboards || []

  return list.find(function (keyboard) {
    return keyboard.name === namedByEvent
  }) || list.reduce(function (furthest, keyboard) {
    return layoutIndex(keyboard) > layoutIndex(furthest) ? keyboard : furthest
  }, list[0])
}

function layoutIndex(keyboard) {
  return (keyboard && keyboard.active_layout_index) || 0
}

// Keyboards-only scope: fcitx input methods pass through untouched, exactly as
// the stock widget labels them.
function inputLabel(state, fallback) {
  if (!state || !state.current || state.current.indexOf("keyboard-") === 0) return fallback
  if (state.label) return String(state.label).substring(0, 3)
  var labels = { mozc: "あ", hangul: "한", pinyin: "拼", chewing: "注", cangjie5: "倉" }
  return labels[state.current] || shortLabel(state.language || state.name, {})
}

function inputTooltip(state, layout, multipleLayouts) {
  if (!state || !state.methods || state.methods.length < 2)
    return layout + (multipleLayouts ? " · Shift+Alt" : "")
  var name = state.current && state.current.indexOf("keyboard-") === 0 ? layout : (state.name || layout)
  return name.replace(/^Keyboard - /, "") + " · Shift+Alt"
}

function showIndicator(layoutLabel, multipleLayouts, multipleInputs) {
  return multipleInputs || (layoutLabel !== "" && multipleLayouts)
}

// ---- layout catalog search + add/remove --------------------------------------

// Flat searchable rows from the xkb table: one per layout:variant pair with a
// description. Skipped: entries without a description (models, option groups).
function catalogEntries(table) {
  var out = []
  var descriptions = (table && table.descriptions) || {}
  var briefs = (table && table.briefs) || {}
  for (var key in descriptions) {
    var sep = key.lastIndexOf(":")
    var code = key.slice(0, sep)
    var variant = key.slice(sep + 1)
    if (!/^[a-z0-9_-]+$/.test(code)) continue
    if (variant !== "" && !/^[a-z0-9_-]+$/.test(variant)) continue
    var description = descriptions[key]
    out.push({
      code: code,
      variant: variant,
      description: description,
      label: shortLabel(description, briefs),
      native: nativeName(description)
    })
  }
  out.sort(function (a, b) {
    return a.description < b.description ? -1 : a.description > b.description ? 1 : 0
  })
  return out
}

function searchScore(entry, query) {
  var q = String(query || "").toLowerCase().trim()
  if (q === "") return -1
  var desc = entry.description.toLowerCase()
  var code = entry.code.toLowerCase()
  var variant = entry.variant.toLowerCase()
  if (desc === q || code === q) return 0
  if (desc.indexOf(q) === 0) return 1
  if (code.indexOf(q) === 0) return 2
  if (variant !== "" && variant.indexOf(q) === 0) return 3
  if (desc.indexOf(q) !== -1) return 4
  if (entry.native && entry.native.toLowerCase().indexOf(q) !== -1) return 5
  if (variant !== "" && variant.indexOf(q) !== -1) return 6
  return -1
}

// Top matches first; already-added layouts sink below unseen ones so the list
// offers something new first.
function searchCatalog(rows, query, limit, addedKeys) {
  var scored = []
  for (var i = 0; i < rows.length; i++) {
    var score = searchScore(rows[i], query)
    if (score === -1) continue
    var key = rows[i].code + ":" + rows[i].variant
    scored.push({ entry: rows[i], score: (addedKeys && addedKeys.indexOf(key) !== -1) ? score + 10 : score })
  }
  scored.sort(function (a, b) {
    return a.score - b.score || (a.entry.description < b.entry.description ? -1 : 1)
  })
  return scored.slice(0, Math.max(1, limit || 6)).map(function (s) { return s.entry })
}

// Pure list edits. Variants pair with layouts by position ("de,ara" + ",azerty").
function parseLayoutList(layoutCsv, variantCsv) {
  var codes = String(layoutCsv || "").split(",")
  var variants = String(variantCsv === undefined || variantCsv === null ? "" : variantCsv).split(",")
  var out = []
  for (var i = 0; i < codes.length; i++) {
    if (!codes[i]) continue
    if (!/^[a-z0-9_-]+$/.test(codes[i])) return null
    var variant = variants[i] || ""
    if (variant !== "" && !/^[a-z0-9_-]+$/.test(variant)) return null
    out.push({ code: codes[i], variant: variant })
  }
  return out
}

function serializeLayoutList(items) {
  return {
    layouts: items.map(function (it) { return it.code }).join(","),
    variants: items.map(function (it) { return it.variant }).join(",")
  }
}

// Adding keeps the Latin lead: a non-Latin addition to a list whose first
// entry would stop being Latin-safe gets "us" prepended... in practice the
// first entry never moves on add, so only appending a duplicate or an
// invalid code can fail.
function addLayoutItem(items, code, variant) {
  var list = (items || []).slice()
  if (!/^[a-z0-9_-]+$/.test(code)) return null
  variant = variant || ""
  if (variant !== "" && !/^[a-z0-9_-]+$/.test(variant)) return null
  for (var i = 0; i < list.length; i++) {
    if (list[i].code === code && list[i].variant === variant) return null
  }
  list.push({ code: code, variant: variant })
  return list
}

// Removing the lead entry must keep a Latin layout first: Super bindings
// resolve against the first kb_layout entry and die on non-Latin. Returns
// null when the removal would leave no layouts, or would strand a non-Latin
// lead with no Latin layout left to promote.
function removeLayoutItem(items, index) {
  var list = (items || []).slice()
  if (index < 0 || index >= list.length || list.length < 2) return null
  list.splice(index, 1)
  if (isNonLatin(list[0].code)) {
    var latin = -1
    for (var i = 1; i < list.length; i++) {
      if (!isNonLatin(list[i].code)) { latin = i; break }
    }
    if (latin === -1) return null
    var lead = list.splice(latin, 1)[0]
    list.unshift(lead)
  }
  return list
}

if (typeof module !== "undefined") {
  module.exports = {
    eventKeyboardName: eventKeyboardName,
    isTypedKeyboard: isTypedKeyboard,
    isNonLatin: isNonLatin,
    layoutBriefs: layoutBriefs,
    layoutTable: layoutTable,
    layoutEntries: layoutEntries,
    descriptionFor: descriptionFor,
    mruTarget: mruTarget,
    pushRecent: pushRecent,
    nativeShort: nativeShort,
    nativeName: nativeName,
    selectKeyboard: selectKeyboard,
    shortLabel: shortLabel,
    inputLabel: inputLabel,
    inputTooltip: inputTooltip,
    showIndicator: showIndicator,
    catalogEntries: catalogEntries,
    searchScore: searchScore,
    searchCatalog: searchCatalog,
    parseLayoutList: parseLayoutList,
    serializeLayoutList: serializeLayoutList,
    addLayoutItem: addLayoutItem,
    removeLayoutItem: removeLayoutItem
  }
}
