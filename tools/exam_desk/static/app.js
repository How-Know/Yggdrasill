const state = {
  tab: "search",
  searchLevel: "all",
  missingLevel: "all",
  missingQuery: "",
  missing: [],
  hidden: [],
  searchTimer: 0,
  searchSeq: 0,
  toastTimer: 0,
}

const $ = (id) => document.getElementById(id)

const tabs = [
  ["search", "tab-search", "panel-search"],
  ["import", "tab-import", "panel-import"],
  ["missing", "tab-missing", "panel-missing"],
]

function toast(message) {
  const node = $("toast")
  node.textContent = message
  node.hidden = false
  clearTimeout(state.toastTimer)
  state.toastTimer = setTimeout(() => {
    node.hidden = true
  }, 2500)
}

async function api(path, options) {
  const response = await fetch(path, options)
  const data = await response.json()
  if (!response.ok) throw new Error(data.error || "요청에 실패했습니다")
  return data
}

function showTab(name) {
  state.tab = name
  const index = tabs.findIndex((item) => item[0] === name)
  document.querySelector(".tabs").dataset.index = String(index)
  tabs.forEach(([key, tabId, panelId]) => {
    const selected = key === name
    $(tabId).setAttribute("aria-selected", selected ? "true" : "false")
    $(panelId).hidden = !selected
  })
  if (name === "search") $("search-input").focus()
}

function setLevel(groupId, level, key) {
  state[key] = level
  document.querySelectorAll(`#${groupId} .chip`).forEach((button) => {
    const selected = button.dataset.level === level
    button.classList.toggle("selected", selected)
    button.setAttribute("aria-pressed", selected ? "true" : "false")
  })
}

function emptyNode(message) {
  const node = document.createElement("p")
  node.className = "empty"
  node.textContent = message
  return node
}

function textBlock(title, meta) {
  const wrap = document.createElement("span")
  wrap.className = "row-text"
  const heading = document.createElement("span")
  heading.className = "row-title"
  heading.textContent = title
  const detail = document.createElement("span")
  detail.className = "row-meta"
  detail.textContent = meta
  wrap.append(heading, detail)
  return wrap
}

async function openPath(path) {
  try {
    await api("/api/open", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path }),
    })
  } catch (error) {
    toast(error.message)
  }
}

function renderSearch(data) {
  const list = $("search-list")
  const count = $("search-count")
  list.replaceChildren()
  if (!data || data.empty) {
    count.textContent = ""
    list.append(emptyNode("검색어를 입력하면 두 폴더 안의 시험지를 찾습니다."))
    return
  }
  if (!data.total) {
    count.textContent = "0개"
    list.append(emptyNode("맞는 파일이 없습니다."))
    return
  }
  count.textContent = data.limited
    ? `${data.total.toLocaleString("ko-KR")}개 중 80개`
    : `${data.total.toLocaleString("ko-KR")}개`
  const box = document.createElement("div")
  box.className = "list"
  data.items.forEach((item) => {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "row"
    button.append(textBlock(item.title, item.meta || item.name))
    button.addEventListener("click", () => openPath(item.path))
    box.append(button)
  })
  list.append(box)
}

async function loadSearch(force) {
  const query = $("search-input").value.trim()
  const seq = ++state.searchSeq
  if (!query) {
    renderSearch({ empty: true, total: 0, items: [] })
    return
  }
  $("search-count").textContent = "찾는 중"
  try {
    const data = await api(
      `/api/search?q=${encodeURIComponent(query)}&level=${encodeURIComponent(state.searchLevel)}${force ? "&refresh=1" : ""}`,
    )
    if (seq === state.searchSeq) renderSearch(data)
  } catch (error) {
    if (seq === state.searchSeq) {
      $("search-count").textContent = ""
      toast(error.message)
    }
  }
}

function scheduleSearch() {
  clearTimeout(state.searchTimer)
  state.searchTimer = setTimeout(() => loadSearch(false), 250)
}

function sectionHeader(title) {
  const header = document.createElement("div")
  header.className = "section"
  const bar = document.createElement("span")
  bar.className = "bar"
  const heading = document.createElement("h2")
  heading.textContent = title
  header.append(bar, heading)
  return header
}

function filtered(items) {
  const tokens = state.missingQuery.trim().toLowerCase().split(/\s+/).filter(Boolean)
  return items.filter((item) => {
    if (state.missingLevel !== "all" && item.level !== state.missingLevel) return false
    if (!tokens.length) return true
    const hay = [
      item.school,
      item.grade,
      item.subject,
      item.year,
      `${item.sem}학기`,
      item.exam,
      item.group,
      item.where,
      ...(item.reasons || []),
    ].join(" ").toLowerCase()
    const compact = hay.replace(/\s+/g, "")
    return tokens.every((token) => hay.includes(token) || compact.includes(token.replace(/\s+/g, "")))
  })
}

function missingRow(item, hidden) {
  const row = document.createElement("div")
  row.className = "row"
  const meta = [
    `${item.year}년 ${item.sem}학기 ${item.exam}`,
    item.bucket_label,
    ...(item.reasons || []),
  ].join(" · ")
  row.append(textBlock(`${item.grade} · ${item.subject}`, meta))
  const button = document.createElement("button")
  button.type = "button"
  if (hidden) {
    button.className = "chip"
    button.textContent = "다시 보기"
    button.addEventListener("click", () => restoreItem(item, button))
  } else {
    button.className = "x"
    button.textContent = "×"
    button.setAttribute("aria-label", "이 시험을 목록에서 빼기")
    button.addEventListener("click", () => dismissItem(item, button))
  }
  row.append(button)
  return row
}

function renderGroups(items, host) {
  host.replaceChildren()
  if (!items.length) {
    host.append(emptyNode("해당하는 시험이 없습니다."))
    return
  }
  let levelName = ""
  let schoolName = ""
  let list = null
  items.forEach((item) => {
    if (item.level !== levelName) {
      levelName = item.level
      schoolName = ""
      host.append(sectionHeader(item.level))
    }
    if (item.school !== schoolName) {
      schoolName = item.school
      const heading = document.createElement("h3")
      heading.className = "school"
      heading.textContent = item.school
      const count = document.createElement("span")
      count.textContent = `${items.filter((row) => row.level === item.level && row.school === item.school).length}건`
      heading.append(count)
      list = document.createElement("div")
      list.className = "list"
      host.append(heading, list)
    }
    list.append(missingRow(item, host.id === "hidden-list"))
  })
}

function renderMissing() {
  const items = filtered(state.missing)
  const hidden = filtered(state.hidden)
  const count = $("missing-count")
  if (!state.missing.length && !state.hidden.length && !state.loaded) {
    count.textContent = "읽고 있습니다"
    return
  }
  count.textContent = state.missingQuery || state.missingLevel !== "all"
    ? `${items.length.toLocaleString("ko-KR")}건`
    : `${state.missing.length.toLocaleString("ko-KR")}건`
  renderGroups(items, $("missing-list"))
  $("hidden-summary").textContent = `숨긴 시험 ${hidden.length.toLocaleString("ko-KR")}`
  renderGroups(hidden, $("hidden-list"))
  $("hidden-box").hidden = state.hidden.length === 0
}

async function loadMissing(force) {
  const data = await api(`/api/missing${force ? "?refresh=1" : ""}`)
  state.missing = data.items || []
  state.hidden = data.hidden || []
  state.loaded = true
  renderMissing()
}

async function dismissItem(item, button) {
  button.disabled = true
  try {
    await api("/api/dismiss", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: item.id }),
    })
    await loadMissing(false)
    toast("목록에서 뺐습니다. 숨긴 시험에서 다시 볼 수 있습니다")
  } catch (error) {
    button.disabled = false
    toast(error.message)
  }
}

async function restoreItem(item, button) {
  button.disabled = true
  try {
    await api("/api/restore", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: item.id }),
    })
    await loadMissing(false)
    toast("다시 목록에 넣었습니다")
  } catch (error) {
    button.disabled = false
    toast(error.message)
  }
}

function encodeName(name) {
  return btoa(unescape(encodeURIComponent(name)))
}

function resultRow(result) {
  const row = document.createElement("div")
  row.className = "row"
  const wrap = document.createElement("span")
  wrap.className = "row-text"
  const kicker = document.createElement("span")
  kicker.className = "result-kicker"
  const title = document.createElement("span")
  title.className = "row-title"
  const meta = document.createElement("span")
  meta.className = "row-meta"
  if (result.status === "pending") {
    kicker.textContent = "넣고 있습니다"
    title.textContent = result.from
  } else if (result.status === "created" || result.status === "variant") {
    kicker.textContent = result.status === "created" ? "넣었습니다" : "내용이 달라 구분 이름을 붙였습니다"
    title.textContent = result.name
    meta.textContent = `${result.where} · 원래 이름 ${result.from}`
  } else if (result.status === "same") {
    kicker.textContent = "이미 같은 파일이 있어 건너뛰었습니다"
    title.textContent = result.name
    meta.textContent = result.where
  } else {
    kicker.classList.add("warn")
    kicker.textContent = "넣지 못했습니다"
    title.textContent = result.from || "파일"
    meta.textContent = result.error || ""
  }
  wrap.append(kicker, title, meta)
  row.append(wrap)
  if (result.path && result.status !== "error") {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "chip"
    button.textContent = "열기"
    button.addEventListener("click", () => openPath(result.path))
    row.append(button)
  }
  return row
}

function ensureImportList() {
  let list = $("import-list").querySelector(".list")
  if (!list) {
    list = document.createElement("div")
    list.className = "list"
    $("import-list").replaceChildren(list)
  }
  return list
}

async function uploadFiles(files) {
  showTab("import")
  const list = ensureImportList()
  for (const file of files) {
    if (!file.name.toLowerCase().endsWith(".hml")) {
      list.prepend(resultRow({ status: "error", from: file.name, error: "hml 파일만 넣을 수 있습니다" }))
      continue
    }
    const pending = resultRow({ status: "pending", from: file.name })
    list.prepend(pending)
    try {
      const result = await api("/api/import", {
        method: "POST",
        headers: {
          "Content-Type": "application/octet-stream",
          "X-Filename": encodeName(file.name),
        },
        body: file,
      })
      pending.replaceWith(resultRow(result))
    } catch (error) {
      pending.replaceWith(resultRow({ status: "error", from: file.name, error: error.message }))
    }
  }
  try {
    await Promise.all([loadStatus(true), loadMissing(true)])
  } catch (error) {
    toast(error.message)
  }
}

window.uploadFiles = uploadFiles

async function loadStatus(force) {
  const line = $("status-line")
  try {
    const data = await api(`/api/status${force ? "?refresh=1" : ""}`)
    const high = data.high_count.toLocaleString("ko-KR")
    const mid = data.mid_count.toLocaleString("ko-KR")
    let text = `고등 폴더 ${high}개 · 중등 폴더 ${mid}개`
    if (!data.high_ok || !data.mid_ok) text += " · 이 PC의 드롭박스에서 폴더를 찾지 못했습니다"
    if (data.unread) text += ` · 이름을 읽지 못한 파일 ${data.unread}개`
    line.textContent = text
    line.title = `${data.high_root}\n${data.mid_root}`
  } catch (error) {
    line.textContent = "폴더를 읽지 못했습니다"
    toast(error.message)
  }
}

function bindLevels(groupId, key, after) {
  document.querySelectorAll(`#${groupId} .chip`).forEach((button) => {
    button.addEventListener("click", () => {
      setLevel(groupId, button.dataset.level, key)
      after()
    })
  })
}

tabs.forEach(([name, tabId]) => {
  $(tabId).addEventListener("click", () => showTab(name))
})

$("search-input").addEventListener("input", scheduleSearch)
$("missing-input").addEventListener("input", () => {
  state.missingQuery = $("missing-input").value
  renderMissing()
})
$("refresh").addEventListener("click", async () => {
  const button = $("refresh")
  button.disabled = true
  try {
    await Promise.all([loadStatus(true), loadMissing(true)])
    if ($("search-input").value.trim()) await loadSearch(true)
  } catch (error) {
    toast(error.message)
  } finally {
    button.disabled = false
  }
})
$("file-input").addEventListener("change", () => {
  const files = [...$("file-input").files]
  $("file-input").value = ""
  if (files.length) uploadFiles(files)
})

let dragDepth = 0
document.addEventListener("dragover", (event) => {
  event.preventDefault()
})
document.addEventListener("dragenter", (event) => {
  dragDepth += 1
  document.body.classList.add("dragging")
})
document.addEventListener("dragleave", () => {
  dragDepth = Math.max(0, dragDepth - 1)
  if (!dragDepth) document.body.classList.remove("dragging")
})
document.addEventListener("drop", (event) => {
  event.preventDefault()
  dragDepth = 0
  document.body.classList.remove("dragging")
  const files = [...(event.dataTransfer.files || [])]
  if (files.length) uploadFiles(files)
})

bindLevels("search-levels", "searchLevel", () => loadSearch(false))
bindLevels("missing-levels", "missingLevel", renderMissing)
renderSearch({ empty: true, total: 0, items: [] })
loadStatus(false)
loadMissing(false).catch((error) => toast(error.message))
$("search-input").focus()
