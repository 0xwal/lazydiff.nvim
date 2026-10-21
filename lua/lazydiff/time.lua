-- Author-date formatting. Pure Lua on purpose: no vim API, so the spec can
-- load it without a running editor.
local M = {}

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- Leap year: divisible by 4, except centuries not divisible by 400.
local function is_leap(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function ago(n, unit)
  return ("%d %s%s ago"):format(n, unit, n == 1 and "" or "s")
end

-- Relative age of `epoch`. `now` is only for tests; it defaults to os.time().
function M.relative(epoch, now)
  if type(epoch) ~= "number" then
    return ""
  end
  now = type(now) == "number" and now or os.time()
  local secs = now - epoch
  if secs < 60 then
    return "just now"
  end
  if secs < 3600 then
    return ago(math.floor(secs / 60), "minute")
  end
  if secs < 86400 then
    return ago(math.floor(secs / 3600), "hour")
  end
  local days = math.floor(secs / 86400)
  if days < 30 then
    return ago(days, "day")
  end
  if days < 365 then
    return ago(math.floor(days / 30), "month")
  end
  return ago(math.floor(days / 365), "year")
end

-- Local calendar date of `epoch` as "Aug 3 2025": no leading zero on the day.
function M.absolute(epoch)
  if type(epoch) ~= "number" then
    return ""
  end
  local t = os.date("*t", epoch)
  local month = t and MONTHS[t.month]
  if not month then
    return ""
  end
  return ("%s %d %d"):format(month, t.day, t.year)
end

-- "Aug 3 2025 (6 months ago)" from a printed timestamp and a ready-made
-- relative phrase. `iso` only has to start with a YYYY-MM-DD date; `ago` is
-- used verbatim (a jj template already computed it). Returns "" when `iso`
-- carries no date, so callers can drop the label instead of printing junk.
function M.from_strings(iso, ago)
  if type(iso) ~= "string" then
    return ""
  end
  local y, mo, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  local year = y and tonumber(y)
  local mon = mo and tonumber(mo)
  local month = mon and MONTHS[mon]
  local day = d and tonumber(d)
  if not month or not day then
    return ""
  end
  local limit = DAYS_IN_MONTH[mon]
  if mon == 2 and is_leap(year) then
    limit = 29
  end
  if day < 1 or day > limit then
    return ""
  end
  local date = ("%s %d %d"):format(month, day, year)
  if type(ago) ~= "string" or ago == "" then
    return date
  end
  return date .. " (" .. ago .. ")"
end

-- "Aug 3 2025 (6 months ago)", or just the date when the age is unusable.
function M.label(epoch)
  local date = M.absolute(epoch)
  if date == "" then
    return ""
  end
  local rel = M.relative(epoch)
  if rel == "" then
    return date
  end
  return date .. " (" .. rel .. ")"
end

return M
