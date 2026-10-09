--[[
  Forty Tools for LazyVim: the 42 toolkit (header, norminette, line counts,
  auto-fix) in a single file.

  Install: copy this file to ~/.config/nvim/lua/plugins/forty-tools.lua and
  restart Neovim. Nothing else to install besides norminette itself
  (`pipx install norminette`, or `py -m pip install norminette` on Windows).
  Requires LazyVim (or lazy.nvim) on Neovim 0.11+.

  Set your login below, or from another file without touching this one:
    return { { "forty-tools", opts = { header = { user = "login" } } } }

  Keys (prefix <leader>4, shown by which-key):
    <F1> / <leader>4h  insert or update the 42 header
    <leader>4p         Norminette panel        <leader>4n  check this file
    <leader>4d         check this folder       <leader>4w  check the workspace
    <leader>4f         fix easy errors (file)  <leader>4l  fix this line
    <leader>4m         when norminette runs    <leader>4i  ignore rule at cursor
    <leader>4c         toggle line counts      <leader>4a  set header author to you
    <leader>4?         status / info
  Code actions (<leader>ca) offer the same fixes on norm errors.
]]

-- ┌─ Your settings ────────────────────────────────────────────────────────────
local SETTINGS = {
  header = {
    user = "mgrossen", -- your 42 login, e.g. "login" (else vim.g.user, then $USER)
    mail = "mgrossen@student.42lausanne.ch", -- your 42 email (else vim.g.mail, then <login>@student.42lausanne.ch)
  },
  norminette = {
    run_mode = "live", -- "live" (while typing), "on_save" or "manual"
  },
  -- keymaps = { prefix = "<leader>4" }, -- change the key prefix here (this block only)
}
-- └────────────────────────────────────────────────────────────────────────────

local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local is_win = fn.has("win32") == 1
local is_mac = fn.has("mac") == 1

local M = {}
package.loaded["forty-tools"] = M

local DEFAULTS = {
  header = {
    user = nil,
    mail = nil,
    git = false, -- use `git config --global user.name/user.email` as fallbacks
    auto_update = true, -- refresh filename + Updated: when a modified buffer is written
    update_on_rename = true,
    auto_insert = false, -- insert the header in new files matching auto_insert_patterns
    auto_insert_patterns = { "*.c", "*.h", "*.cc", "*.cpp", "*.hpp", "*.tpp", "*.ipp", "*.cxx", "*.mk", "Makefile", "makefile", "GNUmakefile" },
    keymap = "<F1>",
    asciiart = nil, -- 7 lines of 25 characters to replace the Lausanne art
  },
  norminette = {
    cmd = nil, -- path or argv list; nil = find it (PATH, pip, pipx, Homebrew, python -m)
    run_mode = "live", -- "live" | "on_save" | "manual"
    use_gitignore = false, -- --use-gitignore for folder / workspace runs
    show_notices = true,
    severity = "error", -- "error" or "warn" for norm errors
    ignored_rules = {},
    extra_args = {},
    fix_on_save = false, -- fix the easy errors on :w (never the cursor line, never adds/removes lines)
    quickfix = false, -- also fill the quickfix list after folder / workspace runs
  },
  line_count = {
    enabled = true,
    highlight_overflow = true,
  },
  lsp = true, -- code actions (<leader>ca) for norm errors through a built-in mini language server
  panel = { position = "right", width = 56 },
  keymaps = { prefix = "<leader>4" },
}

M.config = vim.deepcopy(DEFAULTS)

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Forty Tools" })
end

-- ════════════════════════════════════════════════════════════════════════════
-- Persistent toggles (what the panel changes is remembered, like VS Code settings)
-- ════════════════════════════════════════════════════════════════════════════

local State = { data = {} }

function State.path()
  return fn.stdpath("data") .. "/forty-tools.json"
end

function State.load()
  local f = io.open(State.path(), "r")
  if not f then
    State.data = {}
    return
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  State.data = ok and type(data) == "table" and data or {}
end

function State.save()
  local f = io.open(State.path(), "w")
  if f then
    f:write(vim.json.encode(State.data))
    f:close()
  end
end

local PERSISTED = {
  run_mode = { "norminette", "run_mode" },
  ignored_rules = { "norminette", "ignored_rules" },
  fix_on_save = { "norminette", "fix_on_save" },
  show_notices = { "norminette", "show_notices" },
  use_gitignore = { "norminette", "use_gitignore" },
  line_count = { "line_count", "enabled" },
  highlight_overflow = { "line_count", "highlight_overflow" },
}

local function apply_state()
  for key, path in pairs(PERSISTED) do
    if State.data[key] ~= nil then
      M.config[path[1]][path[2]] = State.data[key]
    end
  end
end

--- Changes a toggle at runtime and remembers it.
function M.set(key, value)
  local path = PERSISTED[key]
  M.config[path[1]][path[2]] = value
  State.data[key] = value
  State.save()
  M.refresh_all()
end

-- ════════════════════════════════════════════════════════════════════════════
-- Paths (Windows: one spelling per file whatever the drive letter case)
-- ════════════════════════════════════════════════════════════════════════════

local function norm_path(p)
  p = vim.fs.normalize(p)
  if is_win then
    p = p:gsub("^(%a):", function(d)
      return d:lower() .. ":"
    end)
  end
  return p
end

--- Identity of a file: its real location (symlinks resolved, cached), case-insensitive on Windows.
local real_cache = {}
local function key_of(p)
  local n = norm_path(p)
  local real = real_cache[n]
  if not real then
    local r = uv.fs_realpath(n)
    real = r and norm_path(r) or n
    if r then
      real_cache[n] = real
    end
  end
  return is_win and real:lower() or real
end

local function buf_path(buf)
  local name = api.nvim_buf_get_name(buf)
  return name ~= "" and norm_path(name) or nil
end

local function is_norm_buf(buf)
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return false
  end
  local name = api.nvim_buf_get_name(buf):lower()
  return name:sub(-2) == ".c" or name:sub(-2) == ".h"
end

local function buf_for_path(p)
  local k = key_of(p)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and buf_path(b) and key_of(buf_path(b)) == k then
      return b
    end
  end
end

local function display_path(p)
  return fn.fnamemodify(p, ":~:.")
end

-- ════════════════════════════════════════════════════════════════════════════
-- Header engine (byte-identical to the VS Code extension)
-- ════════════════════════════════════════════════════════════════════════════

local T = {}
T.LENGTH, T.MARGIN, T.LINE_COUNT = 80, 5, 11
T.EMAIL_DOMAIN = "student.42lausanne.ch"
T.ASCII_ART = {
  "        :::      ::::::::",
  "      :+:      :+:    :+:",
  "    +:+ +:+         +:+  ",
  "  +#+  +:+       +#+     ",
  "+#+#+#+#+#+   +#+        ",
  "     #+#    #+#          ",
  "    ###   ########.ch    ",
}

do
  local C = { start = "/*", stop = "*/", fill = "*" }
  local HASH = { start = "#", stop = "#", fill = "*" }
  local SLASH = { start = "//", stop = "//", fill = "*" }
  local XML = { start = "<!--", stop = "-->", fill = "*" }
  local OCAML = { start = "(*", stop = "*)", fill = "*" }
  local PERCENT = { start = "%", stop = "%", fill = "*" }
  local SEMI = { start = ";", stop = ";", fill = "*" }
  local QUOTE = { start = '"', stop = '"', fill = "*" }
  local BANG = { start = "!", stop = "!", fill = "/" }
  local DASH = { start = "--", stop = "--", fill = "-" }
  T.BY_EXTENSION = {
    c = C, h = C, cc = C, hh = C, cpp = C, hpp = C, tpp = C, ipp = C, cxx = C, hxx = C, inl = C,
    go = C, rs = C, php = C, java = C, kt = C, kts = C, css = C, scss = C, swift = C, cs = C,
    js = SLASH, mjs = SLASH, cjs = SLASH, ts = SLASH, jsx = SLASH, tsx = SLASH, dart = SLASH,
    htm = XML, html = XML, xml = XML, svg = XML, tex = PERCENT,
    ml = OCAML, mli = OCAML, mll = OCAML, mly = OCAML, vim = QUOTE,
    el = SEMI, asm = SEMI, s = SEMI, nasm = SEMI,
    f90 = BANG, f95 = BANG, f03 = BANG, f = BANG, ["for"] = BANG,
    lua = DASH, hs = DASH, sql = DASH,
  }
  T.BY_FILETYPE = {
    c = C, cpp = C, cuda = C, objc = C, objcpp = C, go = C, rust = C, php = C, java = C,
    kotlin = C, css = C, scss = C, less = C, swift = C, cs = C,
    javascript = SLASH, typescript = SLASH, javascriptreact = SLASH, typescriptreact = SLASH, jsonc = SLASH, dart = SLASH,
    html = XML, xml = XML, markdown = XML, vue = XML, tex = PERCENT, plaintex = PERCENT, ocaml = OCAML, vim = QUOTE,
    lisp = SEMI, elisp = SEMI, asm = SEMI, nasm = SEMI, fortran = BANG, lua = DASH, haskell = DASH, sql = DASH,
  }
  T.HASH = HASH
end

function T.style_for(filename, filetype)
  local base = filename:match("[^/\\]+$") or filename
  local ext = base:match("^.+%.([^.]+)$")
  if ext and T.BY_EXTENSION[ext:lower()] then
    return T.BY_EXTENSION[ext:lower()]
  end
  return filetype and T.BY_FILETYPE[filetype] or T.HASH
end

function T.format_date(time)
  return os.date("%Y/%m/%d %H:%M:%S", time)
end

function T.fill_line(s)
  return s.start .. " " .. s.fill:rep(T.LENGTH - #s.start - #s.stop - 2) .. " " .. s.stop
end

function T.text_line(s, left, right)
  local room = T.LENGTH - T.MARGIN * 2 - #right
  local text = left:sub(1, room)
  return s.start .. (" "):rep(T.MARGIN - #s.start) .. text .. (" "):rep(room - #text) .. right .. (" "):rep(T.MARGIN - #s.stop) .. s.stop
end

function T.text_room(art)
  return T.LENGTH - T.MARGIN * 2 - #(art or T.ASCII_ART)[1]
end

function T.author_overflow(login, email, art)
  return math.max(0, #("By: " .. login .. " <" .. email .. ">") - T.text_room(art))
end

--- A too-long address is shortened with `...` and keeps its `>`, instead of being cut against the art.
function T.author_text(login, email, art)
  local room = T.text_room(art)
  local full = "By: " .. login .. " <" .. email .. ">"
  if #full <= room then
    return full
  end
  local head = "By: " .. login .. " <"
  local keep = room - #head - 4
  if keep <= 0 then
    return full:sub(1, room)
  end
  local kept = email:sub(1, keep):gsub("[.@]+$", "")
  return head .. kept .. "...>"
end

function T.build(f, s, art)
  art = art or T.ASCII_ART
  local fill, blank = T.fill_line(s), T.text_line(s, "", "")
  return {
    fill,
    blank,
    T.text_line(s, "", art[1]),
    T.text_line(s, f.filename, art[2]),
    T.text_line(s, "", art[3]),
    T.text_line(s, T.author_text(f.login, f.email, art), art[4]),
    T.text_line(s, "", art[5]),
    T.text_line(s, ("Created: %s by %s"):format(f.created, f.created_by), art[6]),
    T.text_line(s, ("Updated: %s by %s"):format(f.updated, f.updated_by), art[7]),
    blank,
    fill,
  }
end

function T.insert_index(first_line)
  return first_line and first_line:sub(1, 2) == "#!" and 1 or 0
end

local function rtrim(s)
  return (s:gsub("%s+$", ""))
end

local function left_text(line, s, art)
  if #line >= T.LENGTH then
    return vim.trim(line:sub(T.MARGIN + 1, T.MARGIN + T.text_room(art)))
  end
  local t = rtrim(line)
  if t:sub(1, #s.start) == s.start and t:sub(-#s.stop) == s.stop then
    return vim.trim(t:sub(#s.start + 1, #t - #s.stop))
  end
  return ""
end

function T.parse(lines, s, art)
  local start = T.insert_index(lines[1])
  if #lines < start + T.LINE_COUNT then
    return nil
  end
  local function at(i)
    return rtrim(lines[start + i + 1])
  end
  local fill, blank = T.fill_line(s), rtrim(T.text_line(s, "", ""))
  if at(0) ~= fill or at(10) ~= fill or at(1) ~= blank or at(9) ~= blank then
    return nil
  end
  local updated = left_text(at(8), s, art)
  if updated:sub(1, 8) ~= "Updated:" then
    return nil
  end
  local created = left_text(at(7), s, art)
  local c_date, c_by = created:match("^Created: (%S+ %S+) by (%S+)")
  local u_date, u_by = updated:match("^Updated: (%S+ %S+) by (%S+)")
  return {
    start = start,
    filename = left_text(at(3), s, art),
    author = left_text(at(5), s, art),
    created = c_date,
    created_by = c_by,
    updated = u_date,
    updated_by = u_by,
  }
end

function T.refresh(existing, s, u, opts)
  opts = opts or {}
  local fresh = T.build({
    filename = u.filename, login = u.login, email = u.email,
    created = u.date, created_by = u.login, updated = u.date, updated_by = u.login,
  }, s, opts.art)
  if opts.author then
    local created = (existing[8] or ""):match("Created: (%S+ %S+) by") or u.date
    fresh[8] = T.text_line(s, ("Created: %s by %s"):format(created, u.login), (opts.art or T.ASCII_ART)[6])
  else
    fresh[6] = existing[6]
    fresh[8] = existing[8]
  end
  return fresh
end

-- ════════════════════════════════════════════════════════════════════════════
-- Identity
-- ════════════════════════════════════════════════════════════════════════════

local git_cache = {}

local function git_config(key)
  if git_cache[key] == nil then
    local ok, res = pcall(function()
      return vim.system({ "git", "config", "--global", "--includes", key }, { text = true }):wait(3000)
    end)
    local out = ok and res and res.code == 0 and vim.trim(res.stdout or "") or ""
    git_cache[key] = out ~= "" and out or false
  end
  return git_cache[key] or nil
end

local function nonempty(v)
  return type(v) == "string" and vim.trim(v) ~= "" and vim.trim(v) or nil
end

function M.identity()
  local h = M.config.header
  local login, login_src = nonempty(h.user), "settings"
  if not login then
    login, login_src = nonempty(vim.g.user), "vim.g.user"
  end
  if not login and h.git then
    login, login_src = git_config("user.name"), "git"
  end
  if not login then
    login, login_src = nonempty(vim.env.USER) or nonempty(vim.env.USERNAME), is_win and "%USERNAME%" or "$USER"
  end
  if not login then
    login, login_src = "marvin", "default"
  end
  local email, email_src = nonempty(h.mail), "settings"
  if not email then
    email, email_src = nonempty(vim.g.mail), "vim.g.mail"
  end
  if not email and h.git then
    email, email_src = git_config("user.email"), "git"
  end
  if not email then
    local mail = nonempty(vim.env.MAIL)
    if mail and mail:match("^[^%s@/]+@[^%s@]+$") then
      email, email_src = mail, "$MAIL"
    end
  end
  if not email then
    email, email_src = login .. "@" .. T.EMAIL_DOMAIN, "default"
  end
  return { login = login, login_source = login_src, email = email, email_source = email_src }
end

-- ════════════════════════════════════════════════════════════════════════════
-- Header in buffers
-- ════════════════════════════════════════════════════════════════════════════

local Header = {}

local function art()
  return M.config.header.asciiart or T.ASCII_ART
end

local function style_of(buf)
  return T.style_for(api.nvim_buf_get_name(buf), vim.bo[buf].filetype)
end

local function lines_of(buf, count)
  return api.nvim_buf_get_lines(buf, 0, count or -1, false)
end

local warned_overflow = false
local function warn_long_author(who)
  if not warned_overflow and T.author_overflow(who.login, who.email, art()) > 0 then
    warned_overflow = true
    notify(("“By: %s <%s>” is too long for the 42 header and was shortened to “%s”."):format(
      who.login, who.email, T.author_text(who.login, who.email, art())), vim.log.levels.WARN)
  end
end

function Header.build(buf)
  local who, now = M.identity(), T.format_date()
  return T.build({
    filename = fn.fnamemodify(api.nvim_buf_get_name(buf), ":t"),
    login = who.login, email = who.email,
    created = now, created_by = who.login, updated = now, updated_by = who.login,
  }, style_of(buf), art())
end

function Header.find(buf)
  return T.parse(lines_of(buf, T.LINE_COUNT + 1), style_of(buf), art())
end

function Header.refresh(buf, opts)
  opts = opts or {}
  local found = Header.find(buf)
  if not found then
    return false
  end
  local who = M.identity()
  local existing = api.nvim_buf_get_lines(buf, found.start, found.start + T.LINE_COUNT, false)
  local fresh = T.refresh(existing, style_of(buf), {
    filename = fn.fnamemodify(api.nvim_buf_get_name(buf), ":t"),
    login = who.login, email = who.email, date = T.format_date(),
  }, { author = opts.author, art = art() })
  local changed = false
  api.nvim_buf_call(buf, function()
    for i, line in ipairs(fresh) do
      if line ~= existing[i] then
        if not changed and opts.join_undo then
          pcall(vim.cmd.undojoin)
        end
        api.nvim_buf_set_lines(buf, found.start + i - 1, found.start + i, false, { line })
        changed = true
      end
    end
  end)
  if opts.author then
    warn_long_author(who)
  end
  return changed
end

local function editable(buf)
  if not vim.bo[buf].modifiable then
    notify("This buffer can't be modified.", vim.log.levels.WARN)
    return false
  end
  return true
end

function M.header(buf)
  buf = (buf and buf ~= 0) and buf or api.nvim_get_current_buf()
  if not editable(buf) then
    return
  end
  if Header.find(buf) then
    Header.refresh(buf)
    return
  end
  local all = lines_of(buf)
  local at = T.insert_index(all[1])
  local header = Header.build(buf)
  local empty = #all == 1 and all[1] == ""
  local next_line = all[at + 1]
  if empty or (next_line and next_line ~= "") then
    table.insert(header, "")
  end
  api.nvim_buf_set_lines(buf, at, at, false, header)
  if empty and buf == api.nvim_get_current_buf() then
    api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(buf), 0 })
  end
  warn_long_author(M.identity())
end

function M.header_author(buf)
  buf = (buf and buf ~= 0) and buf or api.nvim_get_current_buf()
  if not editable(buf) then
    return
  end
  if not Header.find(buf) then
    return M.header(buf)
  end
  Header.refresh(buf, { author = true })
end

--- `42header` / `stdheader` completion items for the line where a header belongs.
function M.completion_items(buf, row, col)
  if buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  if vim.bo[buf].buftype ~= "" or vim.bo[buf].filetype == "json" then
    return {}
  end
  local all = lines_of(buf)
  if row ~= T.insert_index(all[1]) or Header.find(buf) then
    return {}
  end
  local line = all[row + 1] or ""
  if not line:sub(1, col):match("^%s*[%w_/*#-]*$") then
    return {}
  end
  local header = Header.build(buf)
  local rest_of_line = line:sub(col + 1)
  local rest = table.concat(vim.list_slice(all, row + 2), "\n")
  local sep = (vim.trim(rest_of_line .. rest) == "" or vim.trim(rest_of_line) ~= "") and "\n" or ""
  local text = table.concat(header, "\n") .. "\n" .. sep
  local items = {}
  for i, label in ipairs({ "42header", "stdheader" }) do
    items[i] = {
      label = label,
      kind = vim.lsp.protocol.CompletionItemKind.Snippet,
      detail = "42 Lausanne header",
      documentation = { kind = "markdown", value = "```\n" .. table.concat(header, "\n") .. "\n```" },
      sortText = "!" .. i,
      filterText = label,
      insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
      textEdit = { newText = text, range = { start = { line = row, character = 0 }, ["end"] = { line = row, character = col } } },
    }
  end
  return items
end

-- ════════════════════════════════════════════════════════════════════════════
-- Norminette output
-- ════════════════════════════════════════════════════════════════════════════

local P = {}

function P.parse_json(stdout)
  local files, messages, found = {}, {}, false
  for _, raw in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
    raw = raw:gsub("\r$", "")
    local line = vim.trim(raw)
    if line == "" or line:match("^Setting locale to ") then
      -- noise
    elseif line:sub(1, 1) == "{" and line:find('"files"', 1, true) then
      local ok, doc = pcall(vim.json.decode, line)
      if ok and type(doc) == "table" then
        for _, f in ipairs(doc.files or {}) do
          local issues, all_notices = {}, true
          for _, e in ipairs(type(f.errors) == "table" and f.errors or {}) do
            local h = type(e.highlights) == "table" and e.highlights[1] or {}
            local issue = {
              rule = type(e.name) == "string" and e.name or "UNKNOWN",
              message = type(e.text) == "string" and e.text or "",
              level = e.level == "Notice" and "Notice" or "Error",
              line = math.max(1, tonumber(h.lineno) or 1),
              column = math.max(1, tonumber(h.column) or 1),
              length = type(h.length) == "number" and h.length or nil,
            }
            all_notices = all_notices and issue.level == "Notice"
            issues[#issues + 1] = issue
          end
          files[#files + 1] = {
            path = type(f.path) == "string" and f.path or "",
            status = (f.status == "OK" or all_notices) and "OK" or "Error",
            issues = issues,
          }
        end
        found = true
      else
        messages[#messages + 1] = raw
      end
    else
      messages[#messages + 1] = raw
    end
  end
  return found and { files = files, messages = messages } or nil
end

--- The default text output, for norminette versions without `-f json`.
function P.parse_humanized(stdout)
  local files, messages, current = {}, {}, nil
  for _, raw in ipairs(vim.split((stdout or ""):gsub("\27%[[%d;]*m", ""), "\n", { plain = true })) do
    raw = raw:gsub("\r$", "")
    local line = vim.trim(raw)
    if line == "" or line:match("^Setting locale to ") then
      -- noise
    else
      local level, rule, l, c, msg = line:match("^(%a+):%s+([%u%d_]+)%s+%(line:%s*(%d+),%s*col:%s*(%d+)%):%s*(.*)$")
      if level and current and (level == "Error" or level == "Notice") then
        table.insert(current.issues, { level = level, rule = rule, line = tonumber(l), column = tonumber(c), message = vim.trim(msg) })
      else
        local path, status = line:match("^(.+): (OK)!%s*$")
        if not path then
          path, status = line:match("^(.+): (Error)!%s*$")
        end
        if path then
          current = { path = path, status = status, issues = {} }
          files[#files + 1] = current
        else
          messages[#messages + 1] = raw
        end
      end
    end
  end
  return { files = files, messages = messages }
end

function P.parse_version(out)
  return (out or ""):match("norminette%s+(%d[%w%.%-]*)")
end

--- norminette's columns are visual (tabs to the next multiple of 4, one per character);
--- returns the 0-based byte index in the line.
function P.visual_to_byte(line, column)
  local visual, i, n = 1, 1, #line
  while i <= n do
    if visual >= column then
      return i - 1
    end
    if line:byte(i) == 9 then
      visual = visual + 4 - ((visual - 1) % 4)
    else
      visual = visual + 1
    end
    i = i + 1
    while i <= n do
      local b = line:byte(i)
      if b >= 0x80 and b < 0xC0 then
        i = i + 1
      else
        break
      end
    end
  end
  return n
end

local function ch(text, i)
  if i < 0 or i >= #text then
    return nil
  end
  return text:sub(i + 1, i + 1)
end

local function is_ws(c)
  return c == " " or c == "\t"
end

local function in_set(c, set)
  return c ~= nil and set:find(c, 1, true) ~= nil
end

--- [start, stop) bytes to underline for an issue.
function P.issue_span(line, issue)
  if issue.rule == "INVALID_HEADER" or #line == 0 then
    return 0, math.max(#line, 1)
  end
  local start = math.min(P.visual_to_byte(line, issue.column), math.max(#line - 1, 0))
  if issue.length and issue.length > 1 then
    return start, math.min(#line, start + issue.length)
  end
  local at = ch(line, start)
  local ws_rule = issue.rule:find("SPC") or issue.rule:find("SPACE") or issue.rule:find("TAB") or issue.rule:find("WS") or issue.rule:find("INDENT")
  if ws_rule and not is_ws(at) and start > 0 and is_ws(ch(line, start - 1)) then
    local from = start - 1
    while from > 0 and is_ws(ch(line, from - 1)) do
      from = from - 1
    end
    return from, start
  end
  local stop = start + 1
  local function word(c)
    return c ~= nil and c:match("^[%w_]$") ~= nil
  end
  if is_ws(at) then
    while stop < #line and is_ws(ch(line, stop)) do
      stop = stop + 1
    end
  elseif word(at) then
    while stop < #line and word(ch(line, stop)) do
      stop = stop + 1
    end
  end
  return start, stop
end

-- ════════════════════════════════════════════════════════════════════════════
-- Auto-fix (same rules as the VS Code extension)
-- ════════════════════════════════════════════════════════════════════════════

local F = {}

local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

F.SAFE = set_of({
  "SPC_BEFORE_NL", "SPACE_EMPTY_LINE", "CONSECUTIVE_SPC",
  "SPACE_BEFORE_FUNC", "SPACE_REPLACE_TAB", "SPC_INSTEAD_TAB", "MIXED_SPACE_TAB",
  "TOO_FEW_TAB", "TOO_MANY_TAB", "TOO_MANY_WS", "SPC_LINE_START",
  "TAB_INSTEAD_SPC", "TAB_REPLACE_SPACE",
  "SPACE_AFTER_KW", "SPC_BFR_PAR", "NO_SPC_AFR_PAR", "NO_SPC_BFR_PAR",
  "SPC_BFR_OPERATOR", "SPC_AFTER_OPERATOR", "SPC_AFTER_POINTER",
  "RETURN_PARENTHESIS", "NO_ARGS_VOID", "PREPROC_NO_SPACE",
})
F.MANUAL = set_of({
  "EMPTY_LINE_FUNCTION", "CONSECUTIVE_NEWLINES", "EMPTY_LINE_EOF", "EMPTY_LINE_FILE_START",
  "NL_AFTER_VAR_DECL", "NL_AFTER_PREPROC", "NEWLINE_PRECEDES_FUNC",
  "BRACE_NEWLINE", "BRACE_SHOULD_EOL", "TOO_FEW_TAB",
})
local INDENT_RULES = set_of({ "SPACE_REPLACE_TAB", "SPC_INSTEAD_TAB", "MIXED_SPACE_TAB", "TOO_FEW_TAB", "TOO_MANY_TAB", "TOO_MANY_WS", "SPC_LINE_START" })

F.TITLES = {
  SPC_BEFORE_NL = "Remove trailing whitespace", SPACE_EMPTY_LINE = "Remove whitespace on empty line",
  CONSECUTIVE_SPC = "Use a single space", SPACE_BEFORE_FUNC = "Use a tab before the function name",
  SPACE_REPLACE_TAB = "Replace spaces with a tab", SPC_INSTEAD_TAB = "Indent with tabs",
  MIXED_SPACE_TAB = "Indent with tabs only", TOO_FEW_TAB = "Fix indentation", TOO_MANY_TAB = "Fix indentation",
  TOO_MANY_WS = "Fix indentation", SPC_LINE_START = "Remove whitespace at line start",
  TAB_INSTEAD_SPC = "Replace tab with a space", TAB_REPLACE_SPACE = "Replace tab with a space",
  SPACE_AFTER_KW = "Add a space after the keyword", SPC_BFR_PAR = "Add a space before the parenthesis",
  NO_SPC_AFR_PAR = "Remove the space after the parenthesis", NO_SPC_BFR_PAR = "Remove the space before the parenthesis",
  SPC_BFR_OPERATOR = "Add a space before the operator", SPC_AFTER_OPERATOR = "Add a space after the operator",
  SPC_AFTER_POINTER = "Remove the space after *", RETURN_PARENTHESIS = "Wrap the return value in parentheses",
  NO_ARGS_VOID = "Use (void)", PREPROC_NO_SPACE = "Add a space after the directive",
  EMPTY_LINE_FUNCTION = "Remove this empty line", CONSECUTIVE_NEWLINES = "Remove this empty line",
  EMPTY_LINE_EOF = "Remove this empty line", EMPTY_LINE_FILE_START = "Remove this empty line",
  NL_AFTER_VAR_DECL = "Insert an empty line before", NL_AFTER_PREPROC = "Insert an empty line before",
  NEWLINE_PRECEDES_FUNC = "Insert an empty line before", BRACE_NEWLINE = "Move { to its own line",
  BRACE_SHOULD_EOL = "Add the final newline",
}

local function count_char(s, c)
  return select(2, s:gsub(vim.pesc(c), ""))
end

--- The code of a line with comments and string contents blanked out.
local function code_of(line, state)
  local out = {}
  local i, n = 0, #line
  while i < n do
    local c = ch(line, i)
    if state.in_comment then
      if c == "*" and ch(line, i + 1) == "/" then
        state.in_comment = false
        i = i + 1
      end
      out[#out + 1] = " "
    elseif c == "/" and ch(line, i + 1) == "*" then
      state.in_comment = true
      i = i + 1
      out[#out + 1] = "  "
    elseif c == "/" and ch(line, i + 1) == "/" then
      break
    elseif c == '"' or c == "'" then
      out[#out + 1] = c
      i = i + 1
      while i < n and ch(line, i) ~= c do
        if ch(line, i) == "\\" then
          i = i + 1
        end
        i = i + 1
        out[#out + 1] = " "
      end
      out[#out + 1] = c
    else
      out[#out + 1] = c
    end
    i = i + 1
  end
  return table.concat(out)
end

--- Tabs norminette expects at the start of each line (nil where it can't be known safely).
function F.indent_levels(lines)
  local levels = {}
  local state = { in_comment = false }
  local depth, pending, parens = 0, 0, 0
  local header_open, continued, macro = false, false, false
  for idx, line in ipairs(lines) do
    local was_in_comment = state.in_comment
    local code = code_of(line, state)
    local trimmed = vim.trim(code)
    if macro or (not was_in_comment and trimmed:sub(1, 1) == "#") then
      macro = rtrim(line):sub(-1) == "\\"
      levels[idx] = vim.NIL
    elseif trimmed == "" then
      levels[idx] = vim.NIL
    else
      local opens = trimmed:sub(1, 1) == "{"
      local closes = trimmed:sub(1, 1) == "}"
      local level
      if parens > 0 then
        level = nil
      elseif closes then
        level = depth - 1
      elseif opens then
        level = depth
      elseif continued then
        level = nil
      else
        level = depth + pending
      end
      levels[idx] = (level and level >= 0) and level or vim.NIL

      local starts_control = parens == 0
        and (trimmed:match("^else%s+if%f[%W]") or trimmed:match("^if%f[%W]") or trimmed:match("^while%f[%W]") or trimmed:match("^for%f[%W]")) ~= nil
      parens = math.max(0, parens + count_char(code, "(") - count_char(code, ")"))
      if opens then
        pending = 0
      end
      depth = math.max(0, depth + count_char(code, "{") - count_char(code, "}"))
      local last = trimmed:sub(-1)
      if starts_control or header_open then
        header_open = parens > 0
        if not header_open then
          if last == ")" then
            pending = pending + 1
          elseif last == ";" then
            pending = 0
          end
        end
        continued = header_open
      elseif trimmed == "else" or trimmed == "do" then
        pending = pending + 1
        continued = false
      elseif last == ";" or last == "}" or last == "{" then
        if last == ";" then
          pending = 0
        end
        continued = false
      elseif last == ")" and depth == 0 and parens == 0 then
        continued = false
      else
        continued = parens > 0 or not trimmed:match("[;{}]$")
      end
    end
  end
  for i, v in ipairs(levels) do
    if v == vim.NIL then
      levels[i] = false
    end
  end
  return levels -- false = unknown
end

local OPERATORS = {
  "<<=", ">>=", "...", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||",
  "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=",
  "+", "-", "*", "/", "%", "<", ">", "=", "&", "|", "^", "!", "~", "?", ":",
}

local function operator_at(text, i)
  for _, op in ipairs(OPERATORS) do
    if text:sub(i + 1, i + #op) == op then
      return op
    end
  end
end

local function leading_ws(text)
  local n = 0
  while is_ws(ch(text, n)) do
    n = n + 1
  end
  return n
end

local function ws_run_around(text, i)
  local start = i
  if not is_ws(ch(text, i)) then
    if not is_ws(ch(text, i - 1)) then
      return nil
    end
    start = i - 1
  end
  local stop = start
  while start > 0 and is_ws(ch(text, start - 1)) do
    start = start - 1
  end
  while stop < #text and is_ws(ch(text, stop)) do
    stop = stop + 1
  end
  return { start, stop }
end

local function splice(text, start, stop, insert)
  return text:sub(1, start) .. insert .. text:sub(stop + 1)
end

local function is_wrapped(value)
  if value:sub(1, 1) ~= "(" or value:sub(-1) ~= ")" then
    return false
  end
  local depth = 0
  for i = 1, #value do
    local c = value:sub(i, i)
    depth = depth + (c == "(" and 1 or c == ")" and -1 or 0)
    if depth == 0 and i < #value then
      return false
    end
  end
  return true
end

--- Applies one SAFE fix to a line; `i` is the 0-based byte norminette pointed at.
function F.apply_line_fix(text, rule, i, indent)
  local lead = leading_ws(text)
  if INDENT_RULES[rule] and i <= lead then
    if not indent or lead == #text then
      return text
    end
    return ("\t"):rep(indent) .. text:sub(lead + 1)
  end
  if rule == "SPC_BEFORE_NL" or rule == "SPACE_EMPTY_LINE" then
    return (text:gsub("[ \t]+$", ""))
  elseif rule == "CONSECUTIVE_SPC" then
    if i < lead or ch(text, i) ~= " " or ch(text, i + 1) ~= " " then
      return text
    end
    local stop = i
    while ch(text, stop) == " " do
      stop = stop + 1
    end
    return stop >= #text and text or splice(text, i, stop, " ")
  elseif rule == "SPACE_BEFORE_FUNC" or rule == "SPACE_REPLACE_TAB" or rule == "SPC_INSTEAD_TAB" or rule == "MIXED_SPACE_TAB" then
    local run = ws_run_around(text, i)
    if not run or run[1] < lead or run[1] == 0 or run[2] >= #text or not text:sub(run[1] + 1, run[2]):find(" ", 1, true) then
      return text
    end
    return splice(text, run[1], run[2], "\t")
  elseif rule == "TAB_INSTEAD_SPC" or rule == "TAB_REPLACE_SPACE" then
    if ch(text, i) ~= "\t" or i < lead then
      return text
    end
    local run = ws_run_around(text, i)
    return run[2] >= #text and text or splice(text, run[1], run[2], " ")
  elseif rule == "SPACE_AFTER_KW" then
    local word = text:sub(i + 1):match("^[%a_]+")
    local after = word and i + #word or -1
    return (word and ch(text, after) and not is_ws(ch(text, after))) and splice(text, after, after, " ") or text
  elseif rule == "SPC_BFR_PAR" then
    return (in_set(ch(text, i), "([{") and i > 0 and not is_ws(ch(text, i - 1))) and splice(text, i, i, " ") or text
  elseif rule == "NO_SPC_AFR_PAR" then
    if not in_set(ch(text, i), "([{") or not is_ws(ch(text, i + 1)) then
      return text
    end
    local stop = i + 1
    while is_ws(ch(text, stop)) do
      stop = stop + 1
    end
    return stop >= #text and text or splice(text, i + 1, stop, "")
  elseif rule == "NO_SPC_BFR_PAR" then
    if not in_set(ch(text, i), ")]}") or not is_ws(ch(text, i - 1)) then
      return text
    end
    local start = i - 1
    while start > 0 and is_ws(ch(text, start - 1)) do
      start = start - 1
    end
    return start <= lead and text or splice(text, start, i, "")
  elseif rule == "SPC_BFR_OPERATOR" then
    return (operator_at(text, i) and i > 0 and not is_ws(ch(text, i - 1))) and splice(text, i, i, " ") or text
  elseif rule == "SPC_AFTER_OPERATOR" then
    local op = operator_at(text, i)
    local after = op and i + #op or -1
    local c = op and ch(text, after)
    return (op and c and not is_ws(c) and c ~= ";") and splice(text, after, after, " ") or text
  elseif rule == "SPC_AFTER_POINTER" then
    if ch(text, i) ~= "*" then
      return text
    end
    local stars = i
    while ch(text, stars) == "*" do
      stars = stars + 1
    end
    local stop = stars
    while is_ws(ch(text, stop)) do
      stop = stop + 1
    end
    return (stop > stars and stop < #text) and splice(text, stars, stop, "") or text
  elseif rule == "RETURN_PARENTHESIS" then
    local head, value = text:match("^(%s*return)%s+(.-)%s*;%s*$")
    if not head or value == "" or is_wrapped(value) then
      return text
    end
    return head .. " (" .. value .. ");"
  elseif rule == "NO_ARGS_VOID" then
    if ch(text, i) ~= ")" then
      return text
    end
    local k = i - 1
    while k >= 0 and is_ws(ch(text, k)) do
      k = k - 1
    end
    return ch(text, k) == "(" and splice(text, k + 1, i, "void") or text
  elseif rule == "PREPROC_NO_SPACE" then
    return (vim.trim(text):sub(1, 1) == "#" and i > 0 and not is_ws(ch(text, i - 1))) and splice(text, i, i, " ") or text
  end
  return text
end

local PRIORITY = {
  SPC_BEFORE_NL = 0, SPACE_EMPTY_LINE = 0, SPC_AFTER_OPERATOR = 1, SPC_AFTER_POINTER = 1,
  NO_SPC_AFR_PAR = 1, RETURN_PARENTHESIS = 1, NO_ARGS_VOID = 1, SPACE_AFTER_KW = 2,
  CONSECUTIVE_SPC = 3, SPACE_BEFORE_FUNC = 3, SPACE_REPLACE_TAB = 3, TAB_INSTEAD_SPC = 3, TAB_REPLACE_SPACE = 3,
  NO_SPC_BFR_PAR = 4, SPC_BFR_OPERATOR = 5, SPC_BFR_PAR = 5, PREPROC_NO_SPACE = 5,
}

--- Every SAFE fix for a document: { [0-based line] = new text }.
function F.compute_safe(lines, issues, skip)
  skip = skip or {}
  local by_line, any = {}, false
  for _, issue in ipairs(issues) do
    local l = issue.line - 1
    if F.SAFE[issue.rule] and l >= 0 and l < #lines and not skip[l] then
      by_line[l] = by_line[l] or {}
      table.insert(by_line[l], { rule = issue.rule, index = P.visual_to_byte(lines[l + 1], issue.column) })
      any = true
    end
  end
  local levels = any and F.indent_levels(lines) or {}
  local fixed = {}
  for l, list in pairs(by_line) do
    table.sort(list, function(a, b)
      if a.index ~= b.index then
        return a.index > b.index
      end
      return (PRIORITY[a.rule] or 9) < (PRIORITY[b.rule] or 9)
    end)
    local text = lines[l + 1]
    for _, item in ipairs(list) do
      text = F.apply_line_fix(text, item.rule, item.index, levels[l + 1] or nil)
    end
    if text ~= lines[l + 1] then
      fixed[l] = text
    end
  end
  return fixed
end

--- A line-structure fix (only offered as a code action / explicit fix-line, never automatic).
function F.structural(lines, issue)
  local l = issue.line - 1
  local text = lines[l + 1]
  if not text then
    return nil
  end
  local r = issue.rule
  if r == "EMPTY_LINE_FUNCTION" or r == "CONSECUTIVE_NEWLINES" or r == "EMPTY_LINE_EOF" or r == "EMPTY_LINE_FILE_START" then
    return vim.trim(text) == "" and { kind = "delete_line", line = l } or nil
  elseif r == "NL_AFTER_VAR_DECL" or r == "NL_AFTER_PREPROC" or r == "NEWLINE_PRECEDES_FUNC" then
    return (vim.trim(text) ~= "" and (l == 0 or vim.trim(lines[l]) ~= "")) and { kind = "insert_blank_before", line = l } or nil
  elseif r == "BRACE_NEWLINE" or r == "TOO_FEW_TAB" then
    local i = P.visual_to_byte(text, issue.column)
    while is_ws(ch(text, i)) do
      i = i + 1
    end
    local before = rtrim(text:sub(1, i))
    if ch(text, i) ~= "{" or vim.trim(text:sub(i + 2)) ~= "" or vim.trim(before) == "" then
      return nil
    end
    return { kind = "replace_line", line = l, lines = { before, text:sub(1, leading_ws(text)) .. "{" } }
  elseif r == "BRACE_SHOULD_EOL" then
    return (l == #lines - 1 and vim.trim(text) == "}") and { kind = "append_newline", line = l } or nil
  end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Function line counts (like norminette: lines strictly between the braces)
-- ════════════════════════════════════════════════════════════════════════════

local MAX_LINES = 25
local QUALIFIERS = set_of({ "const", "noexcept", "override", "final", "volatile" })

local function is_ident(c)
  return c ~= nil and c:match("^[%w_]$") ~= nil
end

local function function_name(sig, text)
  local e = #sig
  while e >= 1 and is_ident(sig[e].ch) do
    local start = e
    while start > 1 and is_ident(sig[start - 1].ch) and sig[start - 1].at == sig[start].at - 1 do
      start = start - 1
    end
    if not QUALIFIERS[text:sub(sig[start].at + 1, sig[e].at + 1)] then
      return nil
    end
    e = start - 1
  end
  if e < 1 or sig[e].ch ~= ")" then
    return nil
  end
  local open
  for idx, s in ipairs(sig) do
    if s.ch == "=" then
      return nil
    end
    if not open and s.ch == "(" then
      open = idx
    end
  end
  if not open or open <= 1 then
    return "function"
  end
  local j = open - 1
  while j >= 1 and (is_ident(sig[j].ch) or sig[j].ch == ":") and (j == open - 1 or sig[j].at == sig[j + 1].at - 1) do
    j = j - 1
  end
  local name = text:sub(sig[j + 1].at + 1, sig[open - 1].at + 1)
  return name ~= "" and name or "function"
end

function M.find_functions(text)
  local starts = { 0 }
  for i = 1, #text do
    if text:byte(i) == 10 then
      starts[#starts + 1] = i
    end
  end
  local function line_of(offset)
    local lo, hi = 1, #starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= offset then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return lo - 1
  end
  local spans, sig, current = {}, {}, nil
  local depth, at_line_start = 0, true
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    local nx = text:sub(i + 1, i + 1)
    if c == "\n" then
      at_line_start = true
    elseif c == " " or c == "\t" or c == "\r" or c == "\f" or c == "\v" then
      -- whitespace keeps at_line_start
    elseif c == "#" and at_line_start then
      while i <= n and text:sub(i, i) ~= "\n" do
        if text:sub(i, i) == "\\" and text:sub(i + 1, i + 1) == "\n" then
          i = i + 1
        end
        i = i + 1
      end
      at_line_start = true
    else
      at_line_start = false
      if c == "/" and nx == "/" then
        while i <= n and text:sub(i, i) ~= "\n" do
          i = i + 1
        end
        at_line_start = true
      elseif c == "/" and nx == "*" then
        local close = text:find("*/", i + 2, true)
        i = close and close + 1 or n
      elseif c == '"' or c == "'" then
        i = i + 1
        while i <= n and text:sub(i, i) ~= c and text:sub(i, i) ~= "\n" do
          if text:sub(i, i) == "\\" then
            i = i + 1
          end
          i = i + 1
        end
        if depth == 0 then
          sig[#sig + 1] = { ch = "x", at = i - 1 }
        end
      elseif c == "{" then
        if depth == 0 then
          local name = function_name(sig, text)
          current = name and { name = name, start = sig[1].at, open = i - 1 } or nil
        end
        depth = depth + 1
      elseif c == "}" then
        depth = math.max(0, depth - 1)
        if depth == 0 then
          if current then
            local open_line, close_line = line_of(current.open), line_of(i - 1)
            spans[#spans + 1] = {
              name = current.name,
              start_line = line_of(current.start),
              open_line = open_line,
              close_line = close_line,
              lines = math.max(0, close_line - open_line - 1),
            }
            current = nil
          end
          sig = {}
        end
      elseif depth == 0 then
        if c == ";" then
          sig = {}
        else
          sig[#sig + 1] = { ch = c, at = i - 1 }
        end
      end
    end
    i = i + 1
  end
  return spans
end

-- ════════════════════════════════════════════════════════════════════════════
-- Running norminette (macOS, Linux, Windows)
-- ════════════════════════════════════════════════════════════════════════════

local R = { exe = nil, failed = nil, waiting = nil }
local CHILD_ENV = { PYTHONIOENCODING = "utf-8", PYTHONUTF8 = "1", NO_COLOR = "1" }

function R.install_hint()
  if is_win then
    return "py -m pip install --upgrade norminette", "pipx install norminette"
  end
  return "pipx install norminette", "python3 -m pip install --user --upgrade norminette"
end

local function reversed_glob(pattern)
  local list = fn.glob(pattern, false, true)
  local out = {}
  for i = #list, 1, -1 do
    out[#out + 1] = list[i]
  end
  return out
end

--- Where norminette usually lives; a Dock/Start-menu Neovim doesn't always have the shell's PATH.
function R.candidates()
  local configured = M.config.norminette.cmd
  if type(configured) == "table" then
    return { configured }
  elseif type(configured) == "string" and configured ~= "" and configured ~= "norminette" then
    return { { configured } }
  end
  local list, home = { { "norminette" } }, uv.os_homedir()
  local function add(p)
    if uv.fs_stat(p) then
      list[#list + 1] = { p }
    end
  end
  local function add_all(pattern)
    for _, p in ipairs(reversed_glob(pattern)) do
      add(p)
    end
  end
  if is_win then
    local appdata = vim.env.APPDATA or (home .. "/AppData/Roaming")
    local local_appdata = vim.env.LOCALAPPDATA or (home .. "/AppData/Local")
    add(home .. "/.local/bin/norminette.exe")
    add_all(appdata .. "/Python/Python3*/Scripts/norminette.exe")
    add_all(local_appdata .. "/Programs/Python/Python3*/Scripts/norminette.exe")
    add_all(local_appdata .. "/Packages/PythonSoftwareFoundation.Python.3*/LocalCache/local-packages/Python3*/Scripts/norminette.exe")
    add_all((vim.env.ProgramFiles or "C:/Program Files") .. "/Python3*/Scripts/norminette.exe")
    add_all("C:/Python3*/Scripts/norminette.exe")
    vim.list_extend(list, { { "py", "-3", "-m", "norminette" }, { "python", "-m", "norminette" }, { "python3", "-m", "norminette" } })
  else
    add(home .. "/.local/bin/norminette")
    if is_mac then
      add("/opt/homebrew/bin/norminette")
      add("/usr/local/bin/norminette")
      add_all("/Library/Frameworks/Python.framework/Versions/3*/bin/norminette")
      add_all(home .. "/Library/Python/3*/bin/norminette")
    else
      for _, p in ipairs({ "/usr/local/bin/norminette", "/usr/bin/norminette", "/home/linuxbrew/.linuxbrew/bin/norminette", home .. "/.linuxbrew/bin/norminette", "/snap/bin/norminette" }) do
        add(p)
      end
    end
    vim.list_extend(list, { { "python3", "-m", "norminette" }, { "python", "-m", "norminette" } })
    if uv.fs_stat("/.flatpak-info") then
      vim.list_extend(list, { { "flatpak-spawn", "--host", "norminette" }, { "flatpak-spawn", "--host", "python3", "-m", "norminette" } })
    end
  end
  return list
end

--- `.cmd` / `.bat` wrappers on Windows go through cmd.exe.
local function launchable(argv)
  local exe = argv[1]:lower()
  if is_win and (exe:match("%.cmd$") or exe:match("%.bat$")) then
    return vim.list_extend({ "cmd.exe", "/d", "/s", "/c" }, argv), true
  end
  return argv, false
end

local function spawn(argv, opts, on_exit)
  local real = launchable(argv)
  return vim.system(real, vim.tbl_extend("force", { text = true, env = CHILD_ENV }, opts or {}), on_exit)
end

--- Calls back with the norminette executable (found once, asynchronously), or nil + reason.
function R.with_exe(cb)
  if R.exe then
    return cb(R.exe)
  elseif R.failed then
    return cb(nil, R.failed)
  elseif R.waiting then
    table.insert(R.waiting, cb)
    return
  end
  R.waiting = { cb }
  local cands, failures = R.candidates(), {}
  local function flush(exe, err)
    local waiting = R.waiting or {}
    R.waiting = nil
    for _, w in ipairs(waiting) do
      w(exe, err)
    end
    M.refresh_panel()
  end
  local function try(i)
    if i > #cands then
      R.failed = "norminette was not found.\n" .. table.concat(failures, "\n")
      return flush(nil, R.failed)
    end
    local argv = cands[i]
    local ok, err = pcall(spawn, vim.list_extend(vim.deepcopy(argv), { "-v" }), {}, function(res)
      local out = (res.stdout or "") .. (res.stderr or "")
      local version = P.parse_version(out)
      if res.code == 0 and version then
        vim.schedule(function()
          spawn(vim.list_extend(vim.deepcopy(argv), { "-h" }), {}, function(help)
            R.exe = { argv = argv, version = version, json = ((help.stdout or "") .. (help.stderr or "")):find("--format", 1, true) ~= nil }
            vim.schedule(function()
              flush(R.exe)
            end)
          end)
        end)
      else
        failures[#failures + 1] = table.concat(argv, " ") .. ": " .. vim.trim(out):gsub("\n.*", "")
        vim.schedule(function()
          try(i + 1)
        end)
      end
    end)
    if not ok then
      failures[#failures + 1] = table.concat(argv, " ") .. ": " .. tostring(err):gsub("\n.*", "")
      try(i + 1)
    end
  end
  try(1)
end

function R.reset()
  R.exe, R.failed, R.waiting = nil, nil, nil
end

local function quote(a)
  if a:match("^[%w@%%+=:,./\\_-]+$") then
    return a
  end
  return is_win and ('"' .. a:gsub('"', '\\"') .. '"') or ("'" .. a:gsub("'", "'\\''") .. "'")
end

--- Builds the command line. `req`: { targets, cwd, content = { text, filename }, flags, mode }.
local function build(exe, req)
  local argv = vim.deepcopy(exe.argv)
  if exe.json then
    vim.list_extend(argv, { "-f", "json" })
  end
  for _, flag in ipairs(req.flags or {}) do
    -- --use-gitignore needs real paths inside the repository; it breaks --cfile and temp copies.
    if not (req.content and flag == "--use-gitignore") then
      argv[#argv + 1] = flag
    end
  end
  local temp, display
  if req.content then
    -- norminette's lexer chokes on '\r' in --cfile text.
    local text = req.content.text:gsub("\r\n?", "\n")
    local _, needs_shell = launchable(exe.argv)
    if req.mode == "tempfile" or needs_shell or #text > (is_win and 24000 or 100000) then
      local dir = fn.tempname()
      fn.mkdir(dir, "p")
      temp = dir .. "/" .. fn.fnamemodify(req.content.filename, ":t")
      local f = assert(io.open(temp, "wb"))
      f:write(text)
      f:close()
      argv[#argv + 1] = temp
      display = vim.list_extend(vim.deepcopy(argv), {})
      display[#display] = req.content.filename
    else
      local is_h = req.content.filename:lower():sub(-2) == ".h"
      vim.list_extend(argv, { is_h and "--hfile" or "--cfile", text, "--filename", req.content.filename })
      display = vim.deepcopy(argv)
      display[#display - 2] = "<buffer>"
    end
  else
    vim.list_extend(argv, req.targets)
  end
  display = display or argv
  return argv, temp, table.concat(vim.tbl_map(quote, display), " ")
end

local function outcome_of(exe, res, temp, req, started, display)
  local stdout = res.stdout or ""
  local json = exe.json and P.parse_json(stdout) or nil
  local parsed = json or P.parse_humanized(stdout)
  for _, l in ipairs(vim.split(res.stderr or "", "\n", { plain = true })) do
    if vim.trim(l) ~= "" and not l:match("^Setting locale to ") then
      parsed.messages[#parsed.messages + 1] = l
    end
  end
  if temp then
    for _, f in ipairs(parsed.files) do
      f.path = req.content.filename
    end
    fn.delete(fn.fnamemodify(temp, ":h"), "rf")
  end
  parsed.structured = not exe.json or json ~= nil
  parsed.code = res.code
  parsed.signal = res.signal
  parsed.duration = (uv.hrtime() - started) / 1e6
  parsed.command = display
  parsed.raw = stdout .. (res.stderr or "")
  return parsed
end

--- Runs norminette; cb(outcome) on the main loop. Returns a handle with :kill().
function R.run(req, cb)
  local handle = { killed = false }
  R.with_exe(function(exe, err)
    if not exe then
      return cb(nil, err)
    end
    if handle.killed then
      return
    end
    local started = uv.hrtime()
    local argv, temp, display = build(exe, req)
    local ok, proc = pcall(spawn, argv, { cwd = req.cwd }, function(res)
      vim.schedule(function()
        if not handle.killed then
          cb(outcome_of(exe, res, temp, req, started, display))
        elseif temp then
          fn.delete(fn.fnamemodify(temp, ":h"), "rf")
        end
      end)
    end)
    if not ok then
      return cb(nil, tostring(proc))
    end
    handle.proc = proc
  end)
  function handle:kill()
    self.killed = true
    if self.proc then
      pcall(self.proc.kill, self.proc, 15)
    end
  end
  return handle
end

--- Synchronous run (fix on save), when norminette was already found.
function R.run_sync(req, timeout)
  if not R.exe then
    return nil
  end
  local started = uv.hrtime()
  local argv, temp, display = build(R.exe, req)
  local ok, res = pcall(function()
    return spawn(argv, { cwd = req.cwd }):wait(timeout or 4000)
  end)
  if not ok or not res then
    return nil
  end
  return outcome_of(R.exe, res, temp, req, started, display)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Norminette results, diagnostics and run modes
-- ════════════════════════════════════════════════════════════════════════════

local N = {
  ns = api.nvim_create_namespace("forty-tools.norminette"),
  results = {}, -- key → { path, status, issues }
  timers = {},
  jobs = {},
  main = nil,
  last_run = nil,
  log = {},
}

local function flags_for_run()
  local o = M.config.norminette
  local flags = {}
  if o.use_gitignore then
    flags[#flags + 1] = "--use-gitignore"
  end
  vim.list_extend(flags, o.extra_args or {})
  return flags
end

local function ignored_set()
  return set_of(M.config.norminette.ignored_rules or {})
end

local function hidden(issue, ignored)
  return ignored[issue.rule] or (not M.config.norminette.show_notices and issue.level == "Notice")
end

local function log(command, raw)
  table.insert(N.log, "$ " .. command)
  for _, l in ipairs(vim.split(vim.trim(raw or ""), "\n", { plain = true })) do
    table.insert(N.log, l)
  end
  while #N.log > 2000 do
    table.remove(N.log, 1)
  end
end

--- Pushes a file's results into vim.diagnostic (only for loaded buffers).
function N.publish(path)
  local buf = buf_for_path(path)
  if not buf then
    return
  end
  local result = N.results[key_of(path)]
  if not result then
    vim.diagnostic.reset(N.ns, buf)
    return
  end
  local ignored = ignored_set()
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local error_sev = M.config.norminette.severity == "warn" and vim.diagnostic.severity.WARN or vim.diagnostic.severity.ERROR
  local diags = {}
  for _, issue in ipairs(result.issues) do
    if not hidden(issue, ignored) then
      local lnum = math.min(issue.line - 1, math.max(#lines - 1, 0))
      local text = lines[lnum + 1] or ""
      local s, e = P.issue_span(text, issue)
      diags[#diags + 1] = {
        lnum = lnum, col = s, end_lnum = lnum, end_col = e,
        severity = issue.level == "Notice" and vim.diagnostic.severity.INFO or error_sev,
        message = issue.message, source = "norminette", code = issue.rule,
        user_data = { issue = issue },
      }
    end
  end
  vim.diagnostic.set(N.ns, buf, diags)
end

function N.publish_all()
  for _, r in pairs(N.results) do
    N.publish(r.path)
  end
end

local function buffer_text(buf)
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  if vim.bo[buf].eol or vim.bo[buf].fixeol then
    text = text .. "\n"
  end
  return text
end

local function cwd_for(path)
  local dir = fn.isdirectory(path) == 1 and path or fn.fnamemodify(path, ":h")
  return dir ~= "" and dir or fn.getcwd()
end

--- Checks one buffer as it is (unsaved text included); stale results are dropped.
function M.check(buf)
  buf = (buf and buf ~= 0) and buf or api.nvim_get_current_buf()
  if not is_norm_buf(buf) or not buf_path(buf) then
    return
  end
  local path, tick = buf_path(buf), api.nvim_buf_get_changedtick(buf)
  local k = key_of(path)
  if N.jobs[k] then
    N.jobs[k]:kill()
  end
  N.jobs[k] = R.run({ flags = flags_for_run(), cwd = cwd_for(path), content = { text = buffer_text(buf), filename = path } }, function(out)
    N.jobs[k] = nil
    if not out or not out.structured or not api.nvim_buf_is_valid(buf) or api.nvim_buf_get_changedtick(buf) ~= tick then
      return
    end
    local file = out.files[1]
    if not file then
      return
    end
    file.path = path
    N.results[k] = file
    N.publish(path)
    M.refresh_panel()
  end)
end

local function schedule_live(buf)
  if M.config.norminette.run_mode ~= "live" or not is_norm_buf(buf) then
    return
  end
  local timer = N.timers[buf]
  if not timer then
    timer = uv.new_timer()
    N.timers[buf] = timer
  end
  timer:stop()
  timer:start(500, 0, vim.schedule_wrap(function()
    if api.nvim_buf_is_valid(buf) then
      M.check(buf)
    end
  end))
end

--- Targets for the panel / commands: "file", "folder", "workspace" or explicit paths.
local Panel -- defined below

--- The file the user is working on: the last normal window, never the panel itself.
local function source_buf()
  local function usable(win)
    if not (win and api.nvim_win_is_valid(win)) or (Panel and win == Panel.win) then
      return nil
    end
    local b = api.nvim_win_get_buf(win)
    return (vim.bo[b].buftype == "" and not (Panel and b == Panel.buf)) and b or nil
  end
  local b = usable(M.panel_source_win) or usable(api.nvim_get_current_win())
  if b then
    return b
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    b = usable(win)
    if b then
      M.panel_source_win = win
      return b
    end
  end
  return api.nvim_get_current_buf()
end

local function workspace_root()
  local ok, root = pcall(function()
    return _G.LazyVim and _G.LazyVim.root and _G.LazyVim.root()
  end)
  return ok and root or fn.getcwd()
end

function M.target_label(kind)
  local buf = source_buf()
  local path = buf_path(buf)
  if kind == "file" then
    return path and is_norm_buf(buf) and display_path(path) or nil
  elseif kind == "folder" then
    return path and (display_path(fn.fnamemodify(path, ":h")) .. "/") or (display_path(fn.getcwd()) .. "/")
  end
  return display_path(workspace_root()) .. "/"
end

--- Runs norminette on a target and shows the results in the panel.
function M.run(kind, paths)
  kind = kind or M.panel_target or "file"
  local buf = source_buf()
  local path = buf_path(buf)
  local req, label
  if paths and #paths > 0 then
    req = { targets = vim.tbl_map(function(p)
      return norm_path(fn.fnamemodify(p, ":p"))
    end, paths) }
    label = #paths == 1 and display_path(req.targets[1]) or (#paths .. " paths")
    req.cwd = cwd_for(req.targets[1])
  elseif kind == "file" then
    if not path or not is_norm_buf(buf) then
      return notify("Open a .c or .h file to check it.", vim.log.levels.WARN)
    end
    req = { cwd = cwd_for(path), content = { text = buffer_text(buf), filename = path } }
    label = display_path(path)
  elseif kind == "folder" then
    local dir = path and fn.fnamemodify(path, ":h") or fn.getcwd()
    req = { targets = { norm_path(dir) }, cwd = dir }
    label = display_path(dir) .. "/"
  else
    local root = workspace_root()
    req = { targets = { norm_path(root) }, cwd = root }
    label = display_path(root) .. "/"
  end
  req.flags = flags_for_run()
  if N.main then
    N.main.handle:kill()
  end
  local current = { label = label, started = uv.hrtime() }
  N.main = current
  M.refresh_panel()
  current.handle = R.run(req, function(out, err)
    if N.main ~= current then
      return
    end
    N.main = nil
    if not out then
      N.last_run = { label = label, error = err, duration = 0 }
      return M.refresh_panel()
    end
    log(out.command, out.raw)
    if not out.structured then
      N.last_run = { label = label, error = table.concat(out.messages, "\n"), duration = out.duration, command = out.command }
      return M.refresh_panel()
    end
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(b) then
        vim.diagnostic.reset(N.ns, b)
      end
    end
    N.results = {}
    for _, f in ipairs(out.files) do
      local p = req.content and req.content.filename or f.path
      if not req.content and not (p:match("^/") or p:match("^%a:[/\\]")) then
        p = vim.fs.joinpath(req.cwd, p)
      end
      -- Keys compare real locations, so symlinked folders and drive-letter case don't matter.
      f.path = norm_path(p)
      N.results[key_of(f.path)] = f
    end
    N.last_run = { label = label, duration = out.duration, messages = out.messages, command = out.command, finished = os.time() }
    N.publish_all()
    if M.config.norminette.quickfix and not req.content then
      M.to_quickfix()
    end
    M.refresh_panel()
    M.refresh_line_counts()
  end)
end

function M.stop()
  if N.main then
    N.main.handle:kill()
    N.main = nil
    N.last_run = { label = "stopped", cancelled = true }
    M.refresh_panel()
  end
end

function M.clear()
  N.results, N.last_run = {}, nil
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) then
      vim.diagnostic.reset(N.ns, b)
    end
  end
  M.refresh_panel()
  M.refresh_line_counts()
end

function M.to_quickfix()
  local items, ignored = {}, ignored_set()
  for _, r in pairs(N.results) do
    for _, issue in ipairs(r.issues) do
      if not hidden(issue, ignored) then
        items[#items + 1] = { filename = r.path, lnum = issue.line, col = issue.column, text = issue.rule .. ": " .. issue.message, type = issue.level == "Notice" and "I" or "E" }
      end
    end
  end
  table.sort(items, function(a, b)
    return a.filename == b.filename and a.lnum < b.lnum or a.filename < b.filename
  end)
  fn.setqflist({}, " ", { title = "Norminette", items = items })
end

function M.set_run_mode(mode)
  if mode ~= "live" and mode ~= "on_save" and mode ~= "manual" then
    return notify("Run mode must be live, on_save or manual.", vim.log.levels.ERROR)
  end
  M.set("run_mode", mode)
  notify("Norminette runs " .. ({ live = "while you type", on_save = "when you save", manual = "only when you ask" })[mode] .. ".")
  if mode ~= "manual" then
    M.check(source_buf())
  end
end

function M.choose_run_mode()
  vim.ui.select({ "live", "on_save", "manual" }, {
    prompt = "When should norminette run?",
    format_item = function(m)
      return ({ live = "Live: while typing, on save and on open", on_save = "On save: on save and on open", manual = "Manual: only Run" })[m]
        .. (m == M.config.norminette.run_mode and "  (current)" or "")
    end,
  }, function(choice)
    if choice then
      M.set_run_mode(choice)
    end
  end)
end

function M.ignore_rule(rule, ignore)
  if not rule or rule == "" then
    return
  end
  local list = vim.deepcopy(M.config.norminette.ignored_rules or {})
  local present = vim.tbl_contains(list, rule)
  if ignore ~= false and not present then
    table.insert(list, rule)
    table.sort(list)
  elseif ignore == false and present then
    list = vim.tbl_filter(function(r)
      return r ~= rule
    end, list)
  end
  M.set("ignored_rules", list)
  notify((ignore == false and "No longer ignoring " or "Ignoring ") .. rule .. ".")
end

--- The rule of the norm diagnostic under the cursor.
local function rule_at_cursor(buf)
  local lnum = api.nvim_win_get_cursor(0)[1] - 1
  local diags = vim.diagnostic.get(buf, { namespace = N.ns, lnum = lnum })
  return diags[1] and diags[1].code or nil
end

-- ════════════════════════════════════════════════════════════════════════════
-- Fixing
-- ════════════════════════════════════════════════════════════════════════════

local function apply_line_map(buf, fixed, join_undo)
  local lines = {}
  for l in pairs(fixed) do
    lines[#lines + 1] = l
  end
  table.sort(lines)
  api.nvim_buf_call(buf, function()
    for idx, l in ipairs(lines) do
      if idx == 1 and join_undo then
        pcall(vim.cmd.undojoin)
      end
      api.nvim_buf_set_lines(buf, l, l + 1, false, { fixed[l] })
    end
  end)
  return #lines
end

local function filtered(issues)
  local ignored = ignored_set()
  return vim.tbl_filter(function(i)
    return not ignored[i.rule]
  end, issues)
end

--- Fixes every easy error in a buffer, re-checking between rounds; cb(lines_changed).
function M.fix(buf, cb, quiet)
  buf = (buf and buf ~= 0) and buf or api.nvim_get_current_buf()
  local function done(n)
    if cb then
      cb(n)
    end
  end
  if not is_norm_buf(buf) then
    notify("Open a .c or .h file to fix.", vim.log.levels.WARN)
    return done(0)
  end
  if not editable(buf) then
    return done(0)
  end
  local path, changed, pass = buf_path(buf), {}, 0
  local function round()
    pass = pass + 1
    local tick = api.nvim_buf_get_changedtick(buf)
    R.run({ flags = flags_for_run(), cwd = cwd_for(path), content = { text = buffer_text(buf), filename = path } }, function(out, err)
      if not out then
        notify(err or "norminette failed", vim.log.levels.ERROR)
        return done(0)
      end
      if not api.nvim_buf_is_valid(buf) or api.nvim_buf_get_changedtick(buf) ~= tick or not out.structured then
        return done(vim.tbl_count(changed))
      end
      local fixed = F.compute_safe(api.nvim_buf_get_lines(buf, 0, -1, false), filtered(out.files[1] and out.files[1].issues or {}))
      if next(fixed) and pass <= 4 then
        for l in pairs(fixed) do
          changed[l] = true
        end
        apply_line_map(buf, fixed, pass > 1)
        return round()
      end
      local n = vim.tbl_count(changed)
      if not quiet then
        notify(n > 0 and ("Fixed norm errors on %d line%s."):format(n, n > 1 and "s" or "") or "Nothing to fix automatically.")
      end
      M.check(buf)
      done(n)
    end)
  end
  round()
end

--- Fixes every file listed in the panel (saved again if they had no unsaved changes).
function M.fix_all()
  local ignored = ignored_set()
  local paths = {}
  for _, r in pairs(N.results) do
    for _, i in ipairs(r.issues) do
      if F.SAFE[i.rule] and not ignored[i.rule] then
        paths[#paths + 1] = r.path
        break
      end
    end
  end
  if #paths == 0 then
    return notify("Nothing to fix automatically.")
  end
  local idx, total = 0, 0
  local function step()
    idx = idx + 1
    local p = paths[idx]
    if not p then
      return notify(("Fixed norm errors on %d line%s in %d file%s."):format(total, total == 1 and "" or "s", #paths, #paths > 1 and "s" or ""))
    end
    local buf = buf_for_path(p)
    local was_loaded = buf ~= nil
    if not buf then
      buf = fn.bufadd(p)
      fn.bufload(buf)
    end
    local was_modified = vim.bo[buf].modified
    M.fix(buf, function(n)
      total = total + n
      if n > 0 and not was_modified then
        api.nvim_buf_call(buf, function()
          vim.cmd("silent noautocmd write")
        end)
        M.check(buf)
      end
      if not was_loaded and not vim.bo[buf].modified then
        pcall(api.nvim_buf_delete, buf, {})
      end
      step()
    end, true)
  end
  step()
end

--- Fixes the line under the cursor, structural fixes included (they are never automatic).
function M.fix_line(buf)
  buf = (buf and buf ~= 0) and buf or api.nvim_get_current_buf()
  local lnum = api.nvim_win_get_cursor(0)[1] - 1
  local diags = vim.diagnostic.get(buf, { namespace = N.ns, lnum = lnum })
  if #diags == 0 then
    return notify("No norm error on this line.")
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local issues = vim.tbl_map(function(d)
    return d.user_data and d.user_data.issue
  end, diags)
  local fixed = F.compute_safe(lines, issues)
  if next(fixed) then
    apply_line_map(buf, fixed, false)
    return M.check(buf)
  end
  for _, issue in ipairs(issues) do
    local s = F.structural(lines, issue)
    if s then
      M.apply_structural(buf, s)
      return M.check(buf)
    end
  end
  notify("This error can't be fixed automatically.")
end

function M.apply_structural(buf, s)
  local line = api.nvim_buf_get_lines(buf, s.line, s.line + 1, false)[1] or ""
  if s.kind == "delete_line" then
    api.nvim_buf_set_lines(buf, s.line, s.line + 1, false, {})
  elseif s.kind == "insert_blank_before" then
    api.nvim_buf_set_lines(buf, s.line, s.line, false, { "" })
  elseif s.kind == "replace_line" then
    api.nvim_buf_set_lines(buf, s.line, s.line + 1, false, s.lines)
  elseif s.kind == "append_newline" then
    -- In Neovim the final newline is the 'eol' option; an extra line would be an empty line at EOF.
    vim.bo[buf].eol = true
    vim.bo[buf].fixeol = true
  end
  return line
end

--- Fix on save: synchronous, skips lines with a cursor, never adds or removes lines.
local function fix_on_write(buf)
  if not R.exe then
    return
  end
  local path = buf_path(buf)
  local out = R.run_sync({ flags = flags_for_run(), cwd = cwd_for(path), content = { text = buffer_text(buf), filename = path } }, 4000)
  if not out or not out.structured or not out.files[1] then
    return
  end
  local skip = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == buf then
      skip[api.nvim_win_get_cursor(win)[1] - 1] = true
    end
  end
  local fixed = F.compute_safe(api.nvim_buf_get_lines(buf, 0, -1, false), filtered(out.files[1].issues), skip)
  if next(fixed) then
    apply_line_map(buf, fixed, true)
  end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Line counts under each function (virtual lines) + overflow highlight
-- ════════════════════════════════════════════════════════════════════════════

local LC = { ns = api.nvim_create_namespace("forty-tools.linecount"), timers = {} }
local FILE_LEVEL = set_of({ "TOO_MANY_LINES", "INVALID_HEADER" })

local function countable(buf)
  local ft = vim.bo[buf].filetype
  return api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and (ft == "c" or ft == "cpp")
end

function LC.render(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, LC.ns, 0, -1)
  if not M.config.line_count.enabled or not countable(buf) then
    return
  end
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local path = buf_path(buf)
  local checked = path and N.results[key_of(path)] ~= nil
  local diags = vim.tbl_filter(function(d)
    return not FILE_LEVEL[d.code] and d.severity ~= vim.diagnostic.severity.INFO
  end, vim.diagnostic.get(buf, { namespace = N.ns }))
  local line_count = api.nvim_buf_line_count(buf)
  for _, f in ipairs(M.find_functions(text)) do
    local inside = 0
    for _, d in ipairs(diags) do
      if d.lnum >= f.start_line and d.lnum <= f.close_line then
        inside = inside + 1
      end
    end
    local over = f.lines - MAX_LINES
    local parts = { ("%d / %d lines"):format(f.lines, MAX_LINES) }
    if over > 0 then
      parts[#parts + 1] = over .. " too many"
    end
    if inside > 0 then
      parts[#parts + 1] = inside .. " norm error" .. (inside > 1 and "s" or "")
    elseif checked and over <= 0 then
      parts[#parts + 1] = "norm OK"
    end
    local bad = over > 0 or inside > 0
    local label = "—— " .. (bad and "✗ " or "") .. table.concat(parts, " · ") .. " ——"
    if f.close_line < line_count then
      api.nvim_buf_set_extmark(buf, LC.ns, f.close_line, 0, {
        virt_lines = { { { label, bad and "FortyToolsLineCountBad" or "FortyToolsLineCount" } } },
      })
    end
    if over > 0 and M.config.line_count.highlight_overflow then
      for l = f.open_line + MAX_LINES + 1, math.min(f.close_line - 1, line_count - 1) do
        api.nvim_buf_set_extmark(buf, LC.ns, l, 0, { line_hl_group = "FortyToolsOverflow", priority = 5 })
      end
    end
  end
end

function LC.schedule(buf, delay)
  local timer = LC.timers[buf]
  if not timer then
    timer = uv.new_timer()
    LC.timers[buf] = timer
  end
  timer:stop()
  timer:start(delay or 120, 0, vim.schedule_wrap(function()
    LC.render(buf)
  end))
end

function M.refresh_line_counts()
  for _, win in ipairs(api.nvim_list_wins()) do
    LC.render(api.nvim_win_get_buf(win))
  end
end

local function blend(fg, bg, alpha)
  local function c(v, s)
    return math.floor(bit.band(bit.rshift(v, s), 0xff))
  end
  local function mix(s)
    return math.floor(c(fg, s) * alpha + c(bg, s) * (1 - alpha) + 0.5)
  end
  return string.format("#%02x%02x%02x", mix(16), mix(8), mix(0))
end

local function set_highlights()
  api.nvim_set_hl(0, "FortyToolsLineCount", { link = "Comment", default = true })
  api.nvim_set_hl(0, "FortyToolsLineCountBad", { link = "DiagnosticError", default = true })
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  local err = api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  if normal.bg and err.fg then
    api.nvim_set_hl(0, "FortyToolsOverflow", { bg = blend(err.fg, normal.bg, 0.14), default = true })
  else
    api.nvim_set_hl(0, "FortyToolsOverflow", { link = "DiffDelete", default = true })
  end
  for name, link in pairs({
    FortyToolsTitle = "Title", FortyToolsOk = "DiagnosticOk", FortyToolsErr = "DiagnosticError",
    FortyToolsNotice = "DiagnosticInfo", FortyToolsMuted = "Comment", FortyToolsRule = "Identifier",
    FortyToolsKey = "Special", FortyToolsSelected = "PmenuSel", FortyToolsFix = "DiagnosticHint",
  }) do
    api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Panel (the VS Code sidebar, as a side window)
-- ════════════════════════════════════════════════════════════════════════════

Panel = { buf = nil, win = nil, rows = {}, collapsed = {}, group = "file", show_help = false, hl = api.nvim_create_namespace("forty-tools.panel") }
M.panel_target = "file"

local function panel_visible()
  return Panel.win and api.nvim_win_is_valid(Panel.win) and Panel.buf and api.nvim_buf_is_valid(Panel.buf)
end

local function visible_issues(r)
  local ignored = ignored_set()
  return vim.tbl_filter(function(i)
    return not hidden(i, ignored)
  end, r.issues)
end

local function sorted_results()
  local list = vim.tbl_values(N.results)
  table.sort(list, function(a, b)
    return display_path(a.path) < display_path(b.path)
  end)
  return list
end

function M.refresh_panel()
  if not panel_visible() then
    return
  end
  local o, lines, marks, rows = M.config.norminette, {}, {}, {}
  local function add(text, row, hls)
    lines[#lines + 1] = text
    rows[#lines] = row
    for _, h in ipairs(hls or {}) do
      marks[#marks + 1] = { #lines - 1, h[1], h[2], h[3] }
    end
  end
  local function seg(options, current)
    local parts, hls, col = {}, {}, 0
    for _, opt in ipairs(options) do
      local label = " " .. opt[2] .. " "
      parts[#parts + 1] = label
      if opt[1] == current then
        hls[#hls + 1] = { col, col + #label, "FortyToolsSelected" }
      end
      col = col + #label + 1
    end
    return table.concat(parts, " "), hls
  end

  add(" 42 Norminette", nil, { { 0, -1, "FortyToolsTitle" } })
  local s, h = seg({ { "file", "File" }, { "folder", "Folder" }, { "workspace", "Workspace" } }, M.panel_target)
  local prefix = " Check     "
  add(prefix .. s, { action = "target" }, vim.tbl_map(function(x)
    return { x[1] + #prefix, x[2] + #prefix, x[3] }
  end, h))
  local target = M.target_label(M.panel_target)
  add("           → " .. (target or "open a .c or .h file"), nil, { { 0, -1, "FortyToolsMuted" } })
  s, h = seg({ { "live", "Live" }, { "on_save", "On save" }, { "manual", "Manual" } }, o.run_mode)
  prefix = " Auto      "
  add(prefix .. s, { action = "mode" }, vim.tbl_map(function(x)
    return { x[1] + #prefix, x[2] + #prefix, x[3] }
  end, h))
  local function flag(on, label)
    return (on and "☑ " or "☐ ") .. label
  end
  add(" Options   " .. table.concat({
    flag(o.fix_on_save, "fix on save [s]"), flag(M.config.line_count.enabled, "line counts [c]"),
  }, "  "), nil, { { 0, 11, "FortyToolsMuted" } })
  add("           " .. table.concat({ flag(o.show_notices, "notices [n]"), flag(o.use_gitignore, ".gitignore [G]") }, "  "))
  add("", nil)

  if R.failed then
    local primary, alt = R.install_hint()
    add(" ✗ norminette not found", nil, { { 0, -1, "FortyToolsErr" } })
    add("   " .. primary, nil, { { 0, -1, "FortyToolsKey" } })
    add("   or " .. alt, nil, { { 0, -1, "FortyToolsKey" } })
    add("   then press R to retry", nil, { { 0, -1, "FortyToolsMuted" } })
    add("", nil)
  end

  local results = sorted_results()
  local errors, failing, notices, ignored_n, fixable = 0, 0, 0, 0, 0
  local ignored = ignored_set()
  for _, r in ipairs(results) do
    local live = 0
    for _, i in ipairs(r.issues) do
      if ignored[i.rule] then
        ignored_n = ignored_n + 1
      elseif i.level == "Notice" then
        notices = notices + 1
      else
        live = live + 1
        if F.SAFE[i.rule] then
          fixable = fixable + 1
        end
      end
    end
    errors = errors + live
    failing = failing + (live > 0 and 1 or 0)
  end

  if N.main then
    add(" ⟳ Checking " .. N.main.label .. "…   (x to stop)", nil, { { 0, -1, "FortyToolsNotice" } })
  elseif N.last_run and N.last_run.error then
    add(" ✗ norminette failed", nil, { { 0, -1, "FortyToolsErr" } })
    for _, l in ipairs(vim.split(N.last_run.error, "\n", { plain = true })) do
      add("   " .. l, nil, { { 0, -1, "FortyToolsMuted" } })
    end
  elseif #results > 0 then
    local details = { #results .. " file" .. (#results > 1 and "s" or "") }
    if notices > 0 and o.show_notices then
      details[#details + 1] = notices .. " notice" .. (notices > 1 and "s" or "")
    end
    if ignored_n > 0 then
      details[#details + 1] = ignored_n .. " ignored"
    end
    if N.last_run and N.last_run.duration then
      details[#details + 1] = ("%.1fs"):format(N.last_run.duration / 1000)
    end
    if errors == 0 then
      add(" ✓ Norm OK!", nil, { { 0, -1, "FortyToolsOk" } })
    else
      add((" ✗ %d error%s in %d file%s"):format(errors, errors > 1 and "s" or "", failing, failing > 1 and "s" or ""), nil, { { 0, -1, "FortyToolsErr" } })
    end
    add("   " .. table.concat(details, " · "), nil, { { 0, -1, "FortyToolsMuted" } })
    if fixable > 0 then
      add((" 🔧 F: fix %d easy error%s"):format(fixable, fixable > 1 and "s" or ""), { action = "fix_all" }, { { 0, -1, "FortyToolsFix" } })
    end
  else
    add(" No results yet: press r to run.", nil, { { 0, -1, "FortyToolsMuted" } })
  end
  add("", nil)

  if #results > 0 then
    add(Panel.group == "rule" and " Results by rule  (g: by file)" or " Results by file  (g: by rule)", nil, { { 0, -1, "FortyToolsTitle" } })
    local function issue_row(r, i, with_file)
      local where = (with_file and (fn.fnamemodify(r.path, ":t") .. ":") or "") .. i.line .. ":" .. i.column
      local mark = F.SAFE[i.rule] and " 🔧" or ""
      local text = "     " .. where .. "  " .. (with_file and "" or (i.rule .. "  ")) .. i.message .. mark
      local hls = { { 5, 5 + #where, "FortyToolsMuted" } }
      if not with_file then
        hls[#hls + 1] = { 7 + #where, 7 + #where + #i.rule, i.level == "Notice" and "FortyToolsNotice" or "FortyToolsErr" }
      end
      add(text, { action = "issue", path = r.path, issue = i }, hls)
    end
    if Panel.group == "rule" then
      local by_rule = {}
      for _, r in ipairs(results) do
        for _, i in ipairs(visible_issues(r)) do
          by_rule[i.rule] = by_rule[i.rule] or {}
          table.insert(by_rule[i.rule], { r = r, i = i })
        end
      end
      local rules = vim.tbl_keys(by_rule)
      table.sort(rules, function(a, b)
        return #by_rule[a] > #by_rule[b] or (#by_rule[a] == #by_rule[b] and a < b)
      end)
      for _, rule in ipairs(rules) do
        local k = "r:" .. rule
        local fold = Panel.collapsed[k] and "▸" or "▾"
        add((" %s %s (%d)"):format(fold, rule, #by_rule[rule]), { action = "toggle", key = k, rule = rule }, { { #fold + 2, #fold + 2 + #rule, "FortyToolsRule" } })
        if not Panel.collapsed[k] then
          for _, x in ipairs(by_rule[rule]) do
            issue_row(x.r, x.i, true)
          end
        end
      end
    else
      for _, r in ipairs(results) do
        local issues = visible_issues(r)
        local live = #vim.tbl_filter(function(i)
          return i.level == "Error"
        end, issues)
        local k = "f:" .. key_of(r.path)
        local icon = live > 0 and "✗" or "✓"
        local fold = #issues > 0 and (Panel.collapsed[k] and "▸" or "▾") or " "
        local label = (" %s %s %s%s"):format(fold, icon, display_path(r.path), #issues > 0 and (" (" .. #issues .. ")") or "")
        add(label, { action = "toggle", key = k, path = r.path }, { { #fold + 2, #fold + 2 + #icon, live > 0 and "FortyToolsErr" or "FortyToolsOk" } })
        if not Panel.collapsed[k] then
          for _, i in ipairs(issues) do
            issue_row(r, i, false)
          end
        end
      end
    end
    add("", nil)
  end

  local ig = M.config.norminette.ignored_rules or {}
  add(" Ignored rules: " .. (#ig > 0 and table.concat(ig, ", ") or "none") .. "  (i / u)", nil, { { 0, 15, "FortyToolsMuted" } })
  if R.exe then
    add(" norminette " .. R.exe.version, nil, { { 0, -1, "FortyToolsMuted" } })
  end
  add("", nil)
  if Panel.show_help then
    for _, l in ipairs({
      " <CR> open / fold   r run   t target   m auto-check mode",
      " F fix all   f fix file   i ignore rule   u unignore",
      " g group   n notices   c line counts   s fix on save",
      " G .gitignore   x stop / clear   R retry   L log   q close",
    }) do
      add(l, nil, { { 0, -1, "FortyToolsMuted" } })
    end
  else
    add(" ? help   r run   F fix   q close", nil, { { 0, -1, "FortyToolsMuted" } })
  end

  vim.bo[Panel.buf].modifiable = true
  api.nvim_buf_set_lines(Panel.buf, 0, -1, false, lines)
  vim.bo[Panel.buf].modifiable = false
  api.nvim_buf_clear_namespace(Panel.buf, Panel.hl, 0, -1)
  for _, m in ipairs(marks) do
    local line = lines[m[1] + 1]
    local stop = m[3] == -1 and #line or math.min(m[3], #line)
    if m[2] < stop then
      api.nvim_buf_set_extmark(Panel.buf, Panel.hl, m[1], m[2], { end_col = stop, hl_group = m[4] })
    end
  end
  Panel.rows = rows
end

local function panel_row()
  return Panel.rows[api.nvim_win_get_cursor(Panel.win)[1]]
end

local function jump_to(path, issue)
  local win = M.panel_source_win
  if not (win and api.nvim_win_is_valid(win)) then
    vim.cmd("wincmd p")
    win = api.nvim_get_current_win()
  end
  api.nvim_set_current_win(win)
  vim.cmd("edit " .. fn.fnameescape(path))
  local buf = api.nvim_get_current_buf()
  local lnum = math.min(issue.line, api.nvim_buf_line_count(buf))
  local text = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  api.nvim_win_set_cursor(0, { lnum, P.visual_to_byte(text, issue.column) })
end

local function cycle(list, current)
  for i, v in ipairs(list) do
    if v == current then
      return list[i % #list + 1]
    end
  end
  return list[1]
end

local function panel_keymaps(buf)
  local function map(lhs, f, desc)
    vim.keymap.set("n", lhs, f, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  local function activate()
    local row = panel_row()
    if not row then
      return
    end
    if row.action == "issue" then
      jump_to(row.path, row.issue)
    elseif row.action == "toggle" then
      Panel.collapsed[row.key] = not Panel.collapsed[row.key]
      M.refresh_panel()
    elseif row.action == "target" then
      M.panel_target = cycle({ "file", "folder", "workspace" }, M.panel_target)
      M.refresh_panel()
    elseif row.action == "mode" then
      M.set_run_mode(cycle({ "live", "on_save", "manual" }, M.config.norminette.run_mode))
    elseif row.action == "fix_all" then
      M.fix_all()
    end
  end
  map("<CR>", activate, "Open / toggle")
  map("o", activate, "Open / toggle")
  map("r", function()
    M.run(M.panel_target)
  end, "Run norminette")
  map("t", function()
    M.panel_target = cycle({ "file", "folder", "workspace" }, M.panel_target)
    M.refresh_panel()
  end, "Change target")
  map("m", function()
    M.set_run_mode(cycle({ "live", "on_save", "manual" }, M.config.norminette.run_mode))
  end, "Change auto-check mode")
  map("F", M.fix_all, "Fix all easy errors")
  map("f", function()
    local row = panel_row()
    if row and row.path then
      local b = buf_for_path(row.path) or fn.bufadd(row.path)
      fn.bufload(b)
      M.fix(b)
    else
      M.fix(source_buf())
    end
  end, "Fix file")
  map("i", function()
    local row = panel_row()
    local rule = row and (row.issue and row.issue.rule or row.rule)
    if rule then
      M.ignore_rule(rule, true)
    else
      vim.ui.input({ prompt = "Rule to ignore: " }, function(r)
        if r then
          M.ignore_rule(r:upper(), true)
        end
      end)
    end
  end, "Ignore rule")
  map("u", function()
    local list = M.config.norminette.ignored_rules or {}
    if #list == 0 then
      return notify("No ignored rules.")
    end
    vim.ui.select(list, { prompt = "Stop ignoring" }, function(r)
      if r then
        M.ignore_rule(r, false)
      end
    end)
  end, "Unignore rule")
  map("g", function()
    Panel.group = Panel.group == "file" and "rule" or "file"
    M.refresh_panel()
  end, "Group by file / rule")
  map("n", function()
    M.set("show_notices", not M.config.norminette.show_notices)
  end, "Toggle notices")
  map("c", function()
    M.set("line_count", not M.config.line_count.enabled)
  end, "Toggle line counts")
  map("s", function()
    M.set("fix_on_save", not M.config.norminette.fix_on_save)
  end, "Toggle fix on save")
  map("G", function()
    M.set("use_gitignore", not M.config.norminette.use_gitignore)
  end, "Toggle --use-gitignore")
  map("x", function()
    if N.main then
      M.stop()
    else
      M.clear()
    end
  end, "Stop / clear")
  map("R", function()
    R.reset()
    R.with_exe(function()
      M.refresh_panel()
    end)
  end, "Retry finding norminette")
  map("L", M.show_log, "Show norminette output")
  map("?", function()
    Panel.show_help = not Panel.show_help
    M.refresh_panel()
  end, "Help")
  map("q", M.close_panel, "Close")
end

function M.open_panel()
  local cur = api.nvim_get_current_win()
  if not (Panel.win and cur == Panel.win) then
    M.panel_source_win = cur
  end
  local source = M.panel_source_win
  if panel_visible() then
    api.nvim_set_current_win(Panel.win)
    return M.refresh_panel()
  end
  if not (Panel.buf and api.nvim_buf_is_valid(Panel.buf)) then
    Panel.buf = api.nvim_create_buf(false, true)
    pcall(api.nvim_buf_set_name, Panel.buf, "forty-tools://norminette")
    vim.bo[Panel.buf].filetype = "fortytools"
    vim.bo[Panel.buf].bufhidden = "hide"
    panel_keymaps(Panel.buf)
  end
  local width = M.config.panel.width
  vim.cmd((M.config.panel.position == "left" and "topleft" or "botright") .. " vertical " .. width .. "split")
  Panel.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(Panel.win, Panel.buf)
  -- The split briefly showed the file, which WinEnter took for the working window.
  M.panel_source_win = source
  for k, v in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = true, linebreak = true, cursorline = true, winfixwidth = true, list = false, foldcolumn = "0", spell = false }) do
    vim.wo[Panel.win][k] = v
  end
  R.with_exe(function() end)
  M.refresh_panel()
end

function M.close_panel()
  if panel_visible() then
    api.nvim_win_close(Panel.win, true)
  end
  Panel.win = nil
end

function M.toggle_panel()
  if panel_visible() then
    M.close_panel()
  else
    M.open_panel()
  end
end

function M.show_log()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, #N.log > 0 and N.log or { "(no norminette output yet)" })
  vim.bo[buf].modifiable = false
  vim.cmd("botright split")
  api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
end

-- ════════════════════════════════════════════════════════════════════════════
-- Code actions through a built-in mini language server (<leader>ca)
-- ════════════════════════════════════════════════════════════════════════════

local Lsp = {}

local function line_edit(uri, l, text_len, new_text)
  return { changes = { [uri] = { { range = { start = { line = l, character = 0 }, ["end"] = { line = l, character = text_len } }, newText = new_text } } } }
end

local function structural_edit(uri, lines, s)
  local text = lines[s.line + 1] or ""
  local function r(sl, sc, el, ec)
    return { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } }
  end
  local edit
  if s.kind == "delete_line" then
    edit = { range = r(s.line, 0, s.line + 1, 0), newText = "" }
  elseif s.kind == "insert_blank_before" then
    edit = { range = r(s.line, 0, s.line, 0), newText = "\n" }
  elseif s.kind == "replace_line" then
    edit = { range = r(s.line, 0, s.line, #text), newText = table.concat(s.lines, "\n") }
  else
    edit = { range = r(s.line, #text, s.line, #text), newText = "\n" }
  end
  return { changes = { [uri] = { edit } } }
end

function Lsp.actions(params)
  local uri = params.textDocument.uri
  local buf = vim.uri_to_bufnr(uri)
  local only = params.context and params.context.only
  local fix_all = { title = "Fix all easy norm errors in this file", kind = "source.fixAll.norminette", command = { title = "Fix", command = "forty-tools.fix", arguments = { buf } } }
  if only then
    for _, k in ipairs(only) do
      if k:find("source.fixAll", 1, true) == 1 then
        return { fix_all }
      end
    end
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local first, last = params.range.start.line, params.range["end"].line
  local actions, seen_ignore, any_safe = {}, {}, false
  for _, d in ipairs(vim.diagnostic.get(buf, { namespace = N.ns })) do
    if d.lnum >= first and d.lnum <= last and d.user_data and d.user_data.issue then
      local issue = d.user_data.issue
      if issue.rule == "INVALID_HEADER" then
        actions[#actions + 1] = { title = "Insert 42 header", kind = "quickfix", isPreferred = true, command = { title = "Header", command = "forty-tools.header", arguments = { buf } } }
      elseif F.SAFE[issue.rule] then
        local new = F.compute_safe(lines, { issue })[issue.line - 1]
        if new then
          actions[#actions + 1] = { title = "Fix: " .. F.TITLES[issue.rule], kind = "quickfix", isPreferred = true, edit = line_edit(uri, issue.line - 1, #lines[issue.line], new) }
          any_safe = true
        end
      end
      if F.MANUAL[issue.rule] then
        local s = F.structural(lines, issue)
        if s and s.kind ~= "append_newline" then
          actions[#actions + 1] = { title = "Fix: " .. F.TITLES[issue.rule == "TOO_FEW_TAB" and "BRACE_NEWLINE" or issue.rule], kind = "quickfix", edit = structural_edit(uri, lines, s) }
        end
      end
      if not seen_ignore[issue.rule] then
        seen_ignore[issue.rule] = true
        actions[#actions + 1] = { title = "Ignore norminette rule " .. issue.rule, kind = "quickfix", command = { title = "Ignore", command = "forty-tools.ignore", arguments = { issue.rule } } }
      end
    end
  end
  if any_safe then
    actions[#actions + 1] = vim.tbl_extend("force", fix_all, { kind = "quickfix" })
  end
  return actions
end

local function lsp_server(dispatchers)
  local closing, id = false, 0
  local srv = {}
  function srv.request(method, params, callback, notify_reply)
    id = id + 1
    local this = id
    local function reply(err, result)
      vim.schedule(function()
        callback(err, result)
        if notify_reply then
          notify_reply(this)
        end
      end)
    end
    if method == "initialize" then
      reply(nil, {
        capabilities = {
          codeActionProvider = { codeActionKinds = { "quickfix", "source.fixAll.norminette" } },
          positionEncoding = "utf-8",
          textDocumentSync = { openClose = false, change = 0 },
        },
        serverInfo = { name = "forty-tools" },
      })
    elseif method == "textDocument/codeAction" then
      local ok, result = pcall(Lsp.actions, params)
      reply(nil, ok and result or {})
    elseif method == "shutdown" then
      reply(nil, vim.NIL)
    else
      reply({ code = -32601, message = "unsupported: " .. method }, nil)
    end
    return true, this
  end
  function srv.notify(method)
    if method == "exit" then
      closing = true
      dispatchers.on_exit(0, 15)
    end
    return true
  end
  function srv.is_closing()
    return closing
  end
  function srv.terminate()
    closing = true
  end
  return srv
end

function Lsp.attach(buf)
  if not M.config.lsp or not is_norm_buf(buf) then
    return
  end
  vim.lsp.start({ name = "forty-tools", cmd = lsp_server, root_dir = fn.getcwd() }, {
    bufnr = buf,
    silent = true,
    reuse_client = function(client, config)
      return client.name == config.name
    end,
  })
end

vim.lsp.commands["forty-tools.fix"] = function(cmd)
  M.fix(cmd.arguments and cmd.arguments[1])
end
vim.lsp.commands["forty-tools.header"] = function(cmd)
  M.header(cmd.arguments and cmd.arguments[1])
end
vim.lsp.commands["forty-tools.ignore"] = function(cmd)
  M.ignore_rule(cmd.arguments and cmd.arguments[1], true)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Completion sources
-- ════════════════════════════════════════════════════════════════════════════

local Blink = {}
function Blink.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = Blink })
end
function Blink:enabled()
  return vim.bo.buftype == ""
end
function Blink:get_completions(ctx, callback)
  local ok, items = pcall(M.completion_items, ctx.bufnr, ctx.cursor[1] - 1, ctx.cursor[2])
  callback({ items = ok and items or {}, is_incomplete_forward = false, is_incomplete_backward = false })
end
package.preload["forty-tools.blink"] = function()
  return Blink
end

local Cmp = {}
function Cmp.new()
  return setmetatable({}, { __index = Cmp })
end
function Cmp:is_available()
  return vim.bo.buftype == ""
end
function Cmp:get_debug_name()
  return "forty_header"
end
function Cmp:complete(params, callback)
  local c = params.context.cursor
  local ok, items = pcall(M.completion_items, params.context.bufnr, c.line, c.character)
  callback({ items = ok and items or {}, isIncomplete = false })
end
M.cmp_source = Cmp

-- ════════════════════════════════════════════════════════════════════════════
-- Info
-- ════════════════════════════════════════════════════════════════════════════

function M.info()
  local who, o = M.identity(), M.config.norminette
  local lines = {
    "Forty Tools",
    "",
    ("Header      %s <%s>   (login from %s, email from %s)"):format(who.login, who.email, who.login_source, who.email_source),
  }
  local over = T.author_overflow(who.login, who.email, art())
  if over > 0 then
    lines[#lines + 1] = ("            ⚠ %d characters too long: written as “%s”"):format(over, T.author_text(who.login, who.email, art()))
  end
  vim.list_extend(lines, {
    ("Norminette  %s"):format(R.exe and (R.exe.version .. "  (" .. table.concat(R.exe.argv, " ") .. ")") or (R.failed and "not found" or "looking…")),
    ("Auto-check  %s   fix on save: %s   notices: %s   .gitignore: %s"):format(o.run_mode, tostring(o.fix_on_save), tostring(o.show_notices), tostring(o.use_gitignore)),
    ("Ignored     %s"):format(#(o.ignored_rules or {}) > 0 and table.concat(o.ignored_rules, ", ") or "none"),
    ("Line count  %s   overflow highlight: %s"):format(tostring(M.config.line_count.enabled), tostring(M.config.line_count.highlight_overflow)),
    ("Code actions %s"):format(M.config.lsp and "on (<leader>ca)" or "off"),
    ("Settings    %s"):format(State.path()),
  })
  if R.failed then
    local primary, alt = R.install_hint()
    vim.list_extend(lines, { "", "Install norminette:  " .. primary, "                 or  " .. alt })
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, fn.strdisplaywidth(l))
  end
  local win = api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded", title = " 42 ",
    width = math.min(width + 2, vim.o.columns - 4), height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2), col = math.floor((vim.o.columns - width) / 2),
  })
  vim.keymap.set("n", "q", function()
    api.nvim_win_close(win, true)
  end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function()
    api.nvim_win_close(win, true)
  end, { buffer = buf })
end

-- ════════════════════════════════════════════════════════════════════════════
-- Setup: commands, autocommands
-- ════════════════════════════════════════════════════════════════════════════

function M.refresh_all()
  N.publish_all()
  M.refresh_line_counts()
  M.refresh_panel()
end

local function command(name, f, opts)
  api.nvim_create_user_command(name, f, vim.tbl_extend("force", { force = true }, opts or {}))
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), opts or {})
  State.load()
  apply_state()
  git_cache, warned_overflow = {}, false
  set_highlights()

  command("FortyHeader", function()
    M.header()
  end, { desc = "Insert or update the 42 header" })
  command("Stdheader", function()
    M.header()
  end, { desc = "Insert or update the 42 header" })
  command("FortyHeaderAuthor", function()
    M.header_author()
  end, { desc = "Set the 42 header's author to you" })
  command("Norminette", function(a)
    local arg = a.fargs[1]
    if arg == "file" or arg == "folder" or arg == "workspace" then
      M.panel_target = arg
      M.open_panel()
      M.run(arg)
    else
      M.open_panel()
      M.run(M.panel_target, #a.fargs > 0 and a.fargs or nil)
    end
  end, {
    nargs = "*",
    complete = function(lead)
      return vim.list_extend(vim.tbl_filter(function(x)
        return x:find(lead, 1, true) == 1
      end, { "file", "folder", "workspace" }), fn.getcompletion(lead, "file"))
    end,
    desc = "Run norminette (file, folder, workspace or paths)",
  })
  command("NorminettePanel", M.toggle_panel, { desc = "Toggle the Norminette panel" })
  command("NorminetteMode", function(a)
    if a.args ~= "" then
      M.set_run_mode(a.args)
    else
      M.choose_run_mode()
    end
  end, { nargs = "?", complete = function()
    return { "live", "on_save", "manual" }
  end, desc = "When norminette runs by itself" })
  command("NorminetteFix", function()
    M.fix()
  end, { desc = "Fix the easy norm errors in this file" })
  command("NorminetteFixAll", M.fix_all, { desc = "Fix the easy norm errors in every listed file" })
  command("NorminetteFixLine", function()
    M.fix_line()
  end, { desc = "Fix the norm error(s) on this line" })
  command("NorminetteIgnore", function(a)
    local rule = a.args ~= "" and a.args:upper() or rule_at_cursor(0)
    if rule then
      M.ignore_rule(rule, true)
    else
      notify("No norm error at the cursor.")
    end
  end, { nargs = "?", desc = "Ignore a norminette rule (default: the one at the cursor)" })
  command("NorminetteUnignore", function(a)
    M.ignore_rule(a.args:upper(), false)
  end, { nargs = 1, complete = function()
    return M.config.norminette.ignored_rules or {}
  end, desc = "Stop ignoring a norminette rule" })
  command("NorminetteLog", M.show_log, { desc = "Show the raw norminette output" })
  command("FortyLineCount", function()
    M.set("line_count", not M.config.line_count.enabled)
  end, { desc = "Toggle the function line counts" })
  command("FortyInfo", M.info, { desc = "Forty Tools status" })
  command("FortyReset", function()
    State.data = {}
    State.save()
    M.setup(opts)
    M.refresh_all()
    notify("Panel settings reset to your config.")
  end, { desc = "Forget settings changed from the panel" })

  local group = api.nvim_create_augroup("FortyTools", { clear = true })
  local au = function(event, o)
    api.nvim_create_autocmd(event, vim.tbl_extend("force", { group = group }, o))
  end
  local h = M.config.header
  if h.auto_update then
    au("BufWritePre", {
      callback = function(ev)
        if vim.bo[ev.buf].modified and vim.bo[ev.buf].modifiable then
          Header.refresh(ev.buf, { join_undo = true })
        end
      end,
    })
  end
  au("BufWritePre", {
    callback = function(ev)
      if M.config.norminette.fix_on_save and is_norm_buf(ev.buf) and vim.bo[ev.buf].modifiable then
        fix_on_write(ev.buf)
      end
    end,
  })
  if h.update_on_rename then
    au("BufFilePost", {
      callback = function(ev)
        if vim.bo[ev.buf].modifiable then
          Header.refresh(ev.buf)
        end
      end,
    })
  end
  if h.auto_insert then
    au("BufNewFile", {
      pattern = h.auto_insert_patterns,
      callback = function(ev)
        vim.schedule(function()
          if api.nvim_buf_is_valid(ev.buf) and table.concat(lines_of(ev.buf), "") == "" then
            M.header(ev.buf)
          end
        end)
      end,
    })
  end
  au({ "TextChanged", "TextChangedI" }, {
    callback = function(ev)
      schedule_live(ev.buf)
      if M.config.line_count.enabled and countable(ev.buf) then
        LC.schedule(ev.buf)
      end
    end,
  })
  au("BufWritePost", {
    callback = function(ev)
      if M.config.norminette.run_mode ~= "manual" and is_norm_buf(ev.buf) then
        M.check(ev.buf)
      end
    end,
  })
  au({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    callback = function(ev)
      local buf = ev.buf
      if not is_norm_buf(buf) then
        return
      end
      Lsp.attach(buf)
      local path = buf_path(buf)
      if path and N.results[key_of(path)] then
        N.publish(path)
      elseif M.config.norminette.run_mode ~= "manual" and vim.b[buf].forty_checked == nil then
        vim.b[buf].forty_checked = true
        M.check(buf)
      end
      LC.schedule(buf, 10)
    end,
  })
  au("DiagnosticChanged", {
    callback = function(ev)
      if ev.buf and countable(ev.buf) then
        LC.schedule(ev.buf, 30)
      end
    end,
  })
  au({ "BufWipeout", "BufDelete" }, {
    callback = function(ev)
      for _, timers in ipairs({ N.timers, LC.timers }) do
        if timers[ev.buf] then
          timers[ev.buf]:stop()
          timers[ev.buf]:close()
          timers[ev.buf] = nil
        end
      end
    end,
  })
  au("ColorScheme", { callback = set_highlights })
  au("WinEnter", {
    callback = function()
      local win = api.nvim_get_current_win()
      if win ~= Panel.win and vim.bo[api.nvim_win_get_buf(win)].buftype == "" then
        M.panel_source_win = win
        if panel_visible() then
          vim.schedule(M.refresh_panel)
        end
      end
    end,
  })

  if h.keymap and h.keymap ~= "" then
    vim.keymap.set("n", h.keymap, function()
      M.header()
    end, { desc = "42 header" })
  end
  -- Buffers opened before the plugin loaded (lazy-loading on BufReadPost).
  vim.schedule(function()
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(buf) and is_norm_buf(buf) then
        Lsp.attach(buf)
        if M.config.norminette.run_mode ~= "manual" and vim.b[buf].forty_checked == nil then
          vim.b[buf].forty_checked = true
          M.check(buf)
        end
        LC.schedule(buf, 10)
      end
    end
  end)
  M.did_setup = true
end

-- Internals, for tests.
M._ = { T = T, P = P, F = F, R = R, N = N, LC = LC, Lsp = Lsp, Panel = Panel, State = State }

-- ════════════════════════════════════════════════════════════════════════════
-- lazy.nvim spec
-- ════════════════════════════════════════════════════════════════════════════

local prefix = (SETTINGS.keymaps and SETTINGS.keymaps.prefix) or DEFAULTS.keymaps.prefix
local function k(lhs, f, desc)
  return { prefix .. lhs, f, desc = desc }
end

return {
  {
    "forty-tools", -- no repository: the code is this file
    virtual = true,
    event = { "BufReadPost", "BufNewFile", "BufWritePre" },
    cmd = {
      "FortyHeader", "Stdheader", "FortyHeaderAuthor", "Norminette", "NorminettePanel", "NorminetteMode",
      "NorminetteFix", "NorminetteFixAll", "NorminetteFixLine", "NorminetteIgnore", "NorminetteUnignore",
      "NorminetteLog", "FortyLineCount", "FortyInfo", "FortyReset",
    },
    keys = {
      { (SETTINGS.header and SETTINGS.header.keymap) or DEFAULTS.header.keymap, function() M.header() end, desc = "42 header" },
      k("h", function() M.header() end, "Header: insert / update"),
      k("a", function() M.header_author() end, "Header: author is me"),
      k("p", function() M.toggle_panel() end, "Norminette panel"),
      k("n", function() M.check(0) M.panel_target = "file" if Panel.win then M.refresh_panel() end end, "Check this file"),
      k("d", function() M.open_panel() M.panel_target = "folder" M.run("folder") end, "Check this folder"),
      k("w", function() M.open_panel() M.panel_target = "workspace" M.run("workspace") end, "Check the workspace"),
      k("f", function() M.fix(0) end, "Fix easy norm errors"),
      k("l", function() M.fix_line(0) end, "Fix this line"),
      k("m", function() M.choose_run_mode() end, "When norminette runs"),
      k("i", function()
        local rule = rule_at_cursor(0)
        if rule then M.ignore_rule(rule, true) else notify("No norm error at the cursor.") end
      end, "Ignore rule at cursor"),
      k("c", function() M.set("line_count", not M.config.line_count.enabled) end, "Toggle line counts"),
      k("?", function() M.info() end, "Forty Tools info"),
    },
    opts = SETTINGS,
    config = function(_, opts)
      M.setup(opts)
    end,
  },
  -- `42header` completion with blink.cmp (LazyVim's default)...
  {
    "saghen/blink.cmp",
    optional = true,
    opts = {
      sources = {
        default = { "forty_header" },
        providers = { forty_header = { name = "42header", module = "forty-tools.blink" } },
      },
    },
  },
  -- ...or nvim-cmp (LazyVim's nvim-cmp extra).
  {
    "hrsh7th/nvim-cmp",
    optional = true,
    opts = function(_, opts)
      require("cmp").register_source("forty_header", Cmp.new())
      opts.sources = opts.sources or {}
      table.insert(opts.sources, { name = "forty_header" })
    end,
  },
  {
    "folke/which-key.nvim",
    optional = true,
    opts = { spec = { { prefix, group = "42" } } },
  },
}

