local M = {}

local diff_mod = require("lazydiff.diff")
local config = require("lazydiff.config")

local NS = vim.api.nvim_create_namespace("lazydiff")

function M.namespace()
  return NS
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  end
end

-- Word-level ranges for a change hunk whose lines pair up one-to-one.
-- Returns (old_ranges[i], new_ranges[i]) or nil when word diff doesn't apply.
local function word_ranges(hunk)
  if not config.options.word_diff or hunk.kind ~= "change" or hunk.old_count ~= hunk.new_count then
    return nil
  end
  local olds, news = {}, {}
  for i = 1, hunk.old_count do
    olds[i], news[i] = diff_mod.word_diff(hunk.old_lines[i], hunk.new_lines[i])
  end
  return olds, news
end

local warned = {}

-- Treesitter captures per line index: segs[i] = list of { col_start, col_end, capture_name }.
-- Returns nil when no parser or query exists, or on any error.
local function syntax_segments(text_lines, filetype)
  local ok, result = pcall(function()
    if not filetype or filetype == "" then
      return nil
    end
    local lang = vim.treesitter.language.get_lang(filetype)
    if not lang then
      local key = filetype .. ":lang"
      if not warned[key] then
        warned[key] = true
        vim.notify("lazydiff: syntax highlight skipped: lang is nil for filetype " .. filetype, vim.log.levels.WARN)
      end
      return nil
    end
    local text = table.concat(text_lines, "\n")
    local parser = vim.treesitter.get_string_parser(text, lang)
    local tree = parser:parse()[1]
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
      local key = filetype .. ":query"
      if not warned[key] then
        warned[key] = true
        vim.notify("lazydiff: syntax highlight skipped: query is nil for filetype " .. filetype, vim.log.levels.WARN)
      end
      return nil
    end
    local pending = {}
    local order = 0
    for id, node, metadata in query:iter_captures(tree:root(), text, 0, -1) do
      local name = query.captures[id]
      local meta = metadata and metadata[id]
      local priority = (meta and meta.priority) or 100
      local sr, sc, er, ec = node:range()
      for row = sr, er do
        local line = text_lines[row + 1]
        if line then
          local cs = row == sr and sc or 0
          local ce = row == er and ec or #line
          if ce > cs then
            order = order + 1
            pending[row + 1] = pending[row + 1] or {}
            table.insert(pending[row + 1], {
              cs = cs,
              ce = ce,
              name = name,
              priority = priority,
              order = order,
            })
          end
        end
      end
    end
    local out = {}
    for row, caps in pairs(pending) do
      table.sort(caps, function(a, b)
        if a.priority ~= b.priority then
          return a.priority < b.priority
        end
        local la, lb = a.ce - a.cs, b.ce - b.cs
        if la ~= lb then
          return la > lb
        end
        return a.order < b.order
      end)
      local line_len = #text_lines[row]
      local cols = {}
      for _, cap in ipairs(caps) do
        for c = cap.cs + 1, cap.ce do
          cols[c] = cap.name
        end
      end
      local spans = {}
      local c = 1
      while c <= line_len do
        local name = cols[c]
        local j = c
        while j < line_len and cols[j + 1] == name do
          j = j + 1
        end
        if name then
          table.insert(spans, { c - 1, j, name })
        end
        c = j + 1
      end
      out[row] = spans
    end
    return out
  end)
  if not ok then
    vim.notify("lazydiff: syntax highlight skipped: " .. tostring(result), vim.log.levels.WARN)
    return nil
  end
  return result
end

local syn_groups = {}

-- Highlight group for a treesitter capture: syntax fg on the LazydiffDelete bg.
-- Falls back to LazydiffDelete when the capture has no fg.
local function delete_hl_for(capture_name)
  local safe = capture_name:gsub("[^%w_]", "_")
  if syn_groups[safe] ~= nil then
    return syn_groups[safe]
  end
  local fg = vim.api.nvim_get_hl(0, { name = "@" .. capture_name, link = false }).fg
  if not fg then
    syn_groups[safe] = "LazydiffDelete"
    return "LazydiffDelete"
  end
  local bg = vim.api.nvim_get_hl(0, { name = "LazydiffDelete", link = false }).bg
  local name = "LazydiffDeleteSyn_" .. safe
  vim.api.nvim_set_hl(0, name, { fg = fg, bg = bg, default = true })
  syn_groups[safe] = name
  return name
end

local word_syn_groups = {}

-- Word-changed span: bg of LazydiffDeleteWord, fg of the syntax capture.
-- Falls back to LazydiffDeleteWord when there is no capture.
local function word_hl_for(capture_name)
  if not capture_name then
    return "LazydiffDeleteWord"
  end
  local safe = capture_name:gsub("[^%w_]", "_")
  if word_syn_groups[safe] then
    return word_syn_groups[safe]
  end
  local fg = vim.api.nvim_get_hl(0, { name = "@" .. capture_name, link = false }).fg
  local word = vim.api.nvim_get_hl(0, { name = "LazydiffDeleteWord", link = false })
  if not fg then
    return "LazydiffDeleteWord"
  end
  local name = "LazydiffDeleteWordSyn_" .. safe
  vim.api.nvim_set_hl(0, name, { fg = fg, bg = word.bg, bold = word.bold, underline = word.underline, default = true })
  word_syn_groups[safe] = name
  return name
end

-- A deleted line as virt_text chunks: the sign, then the content split into
-- syntax spans. Word ranges take priority over syntax spans.
local function delete_chunks(content, ranges, sign, segs)
  local chunks = { { sign, "LazydiffDeleteSign" } }
  local len = #content
  local groups = {}
  local caps = {}
  for c = 1, len do
    groups[c] = "LazydiffDelete"
  end
  for _, s in ipairs(segs or {}) do
    local g = delete_hl_for(s[3])
    for c = s[1] + 1, math.min(s[2], len) do
      groups[c] = g
      caps[c] = s[3]
    end
  end
  for _, r in ipairs(ranges or {}) do
    for c = r[1] + 1, math.min(r[2], len) do
      groups[c] = word_hl_for(caps[c])
    end
  end
  local i = 1
  while i <= len do
    local g = groups[i]
    local j = i
    while j < len and groups[j + 1] == g do
      j = j + 1
    end
    chunks[#chunks + 1] = { content:sub(i, j), g }
    i = j + 1
  end
  return chunks
end

-- segs is keyed by baseline row (1-based). Deleted rows are
-- hunk.old_start .. hunk.old_start + hunk.old_count - 1.
local function build_above_virt_lines(bufnr, hunk, signs, show_header, old_word_ranges, segs, author, commit)
  local lines = {}
  local show_author = config.options.show_author_header and author
  local show_commit = type(commit) == "string" and commit ~= ""
  if show_header or show_author or show_commit then
    local chunks = {}
    if show_header then
      chunks[#chunks + 1] = { diff_mod.format_hunk_header(hunk), "LazydiffHunkHeader" }
    end
    if show_author then
      chunks[#chunks + 1] = { "  author: " .. author, "LazydiffHunkHeader" }
    end
    if show_commit then
      local sep = #chunks > 0 and "  " or ""
      chunks[#chunks + 1] = { sep .. commit, "LazydiffHunkHeader" }
    end
    lines[#lines + 1] = chunks
  end
  for i, content in ipairs(hunk.old_lines) do
    local row = hunk.old_start + i - 1
    lines[#lines + 1] = delete_chunks(
      content,
      old_word_ranges and old_word_ranges[i],
      signs.delete,
      segs and segs[row]
    )
  end
  return lines
end

local function set_virt_lines(bufnr, anchor_0based, virt_lines, above)
  if #virt_lines == 0 then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, anchor_0based, 0, {
    virt_lines = virt_lines,
    virt_lines_above = above,
  })
end

local function mark_added_line(bufnr, line_0based, sign_text, word_ranges_for_line)
  -- The + marker goes in the sign column, not as inline virt_text. Three
  -- earlier attempts to render it inline failed in this user's colorscheme
  -- + plugin combination (line bg painted over the virt_text, or some other
  -- extmark plugin overlapped at col 0). Sign column has its own dedicated
  -- render path that no other plugin can paint over.
  --
  -- The hl_group + hl_eol on the same extmark paints the green band across
  -- the buffer text region only.
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, line_0based, 0, {
    sign_text = sign_text,
    sign_hl_group = "LazydiffAddSign",
    end_row = line_0based + 1,
    end_col = 0,
    hl_group = "LazydiffAdd",
    hl_eol = true,
    priority = 1000,
  })
  for _, r in ipairs(word_ranges_for_line or {}) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, line_0based, r[1], {
      end_col = r[2],
      hl_group = "LazydiffAddWord",
      priority = 1001,
    })
  end
end

-- baseline_lines: full baseline file lines. Nil (e.g. scratch float) falls
-- back to plain LazydiffDelete for deleted lines.
function M.render(bufnr, hunks, baseline_lines, author, commit)
  M.clear(bufnr)
  if not hunks or #hunks == 0 then
    return
  end

  local cfg = config.options
  local signs = cfg.signs
  local show_header = cfg.show_hunk_header
  local total_lines = vim.api.nvim_buf_line_count(bufnr)

  -- Parse the full baseline once per render pass, not per hunk.
  local segs
  if baseline_lines and #baseline_lines > 0 then
    segs = syntax_segments(baseline_lines, vim.bo[bufnr].filetype)
  end

  for _, hunk in ipairs(hunks) do
    local old_words, new_words = word_ranges(hunk)
    local above_lines = build_above_virt_lines(bufnr, hunk, signs, show_header, old_words, segs, author, commit)

    if hunk.new_count > 0 then
      -- Hunk has buffer-anchored content: place header+deletes ABOVE the first new line.
      local anchor = math.max(hunk.new_start - 1, 0)
      set_virt_lines(bufnr, anchor, above_lines, true)
      for i = 0, hunk.new_count - 1 do
        local line = hunk.new_start - 1 + i
        if line >= 0 and line < total_lines then
          mark_added_line(bufnr, line, signs.add, new_words and new_words[i + 1])
        end
      end
    else
      -- Pure deletion: new_start is the buffer line AFTER which the deletion sits
      -- (0 if deleted from the top of the file).
      if hunk.new_start == 0 then
        if total_lines > 0 then
          set_virt_lines(bufnr, 0, above_lines, true)
        end
      else
        local anchor = math.min(hunk.new_start - 1, total_lines - 1)
        set_virt_lines(bufnr, anchor, above_lines, false)
      end
    end
  end
end

return M
