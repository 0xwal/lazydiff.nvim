-- Unit tests for lazydiff.time. Pure Lua, no fixtures: the runner registers
-- this file next to spec.lua.
--
--   tests/run.sh

local time = require("lazydiff.time")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(("  ok   %s"):format(name))
  else
    fail = fail + 1
    print(("  FAIL %s   %s"):format(name, detail or ""))
  end
end
local function section(title)
  print(("\n== %s =="):format(title))
end

-- Fixed "now" so relative ages do not depend on the wall clock. Noon avoids
-- the DST edges on the day boundaries.
local now = os.time({ year = 2026, month = 2, day = 1, hour = 12, min = 0, sec = 0 })
-- One wall-clock read, reused, so the default-clock case cannot straddle a
-- second boundary between the check and its detail string.
local wall_now = os.time()
local day = 86400

local function rel(secs)
  return time.relative(now - secs, now)
end

-- ---------------------------------------------------------------------------
section("time.relative")

check("under a minute is 'just now'", rel(30) == "just now", rel(30))
check("5 minutes", rel(5 * 60) == "5 minutes ago", rel(5 * 60))
check("1 minute is singular", rel(60) == "1 minute ago", rel(60))
check("3 hours", rel(3 * 3600) == "3 hours ago", rel(3 * 3600))
check("20 days", rel(20 * day) == "20 days ago", rel(20 * day))
check("200 days is 6 months", rel(200 * day) == "6 months ago", rel(200 * day))
check("800 days is 2 years", rel(800 * day) == "2 years ago", rel(800 * day))
check(
  "the default clock is os.time()",
  time.relative(wall_now - 30) == "just now",
  time.relative(wall_now - 30, wall_now)
)

-- ---------------------------------------------------------------------------
section("time.relative boundaries")

-- Each pair straddles one threshold: the unit name must change exactly once.
check("59 s is still 'just now'", rel(59) == "just now", rel(59))
check("60 s flips to minutes", rel(60) == "1 minute ago", rel(60))
check("3599 s is still minutes", rel(3599) == "59 minutes ago", rel(3599))
check("3600 s flips to hours", rel(3600) == "1 hour ago", rel(3600))
check("29 days is still days", rel(29 * day) == "29 days ago", rel(29 * day))
check("30 days flips to months", rel(30 * day) == "1 month ago", rel(30 * day))
check("364 days is still months", rel(364 * day) == "12 months ago", rel(364 * day))
check("365 days flips to years", rel(365 * day) == "1 year ago", rel(365 * day))

-- ---------------------------------------------------------------------------
section("time.absolute")

local known = os.time({ year = 2025, month = 8, day = 3, hour = 12, min = 0, sec = 0 })
check("known epoch formats as 'Aug 3 2025'", time.absolute(known) == "Aug 3 2025", time.absolute(known))

-- ---------------------------------------------------------------------------
section("time.label")

local label = time.label(known)
check(
  "label is date, middle dot separator, relative age",
  label:match("^Aug 3 2025 %([^%)]+%)$") ~= nil,
  label
)

-- ---------------------------------------------------------------------------
section("time.from_strings")

-- Same shape jj prints: date, clock, offset.
local jj_stamp = "2025-08-03 12:00:00.000 +02:00"

check(
  "date plus ago phrase",
  time.from_strings(jj_stamp, "6 months ago") == "Aug 3 2025 (6 months ago)",
  time.from_strings(jj_stamp, "6 months ago")
)
check(
  "date without an ago phrase",
  time.from_strings("2025-08-03T12:00:00", nil) == "Aug 3 2025",
  time.from_strings("2025-08-03T12:00:00", nil)
)
check(
  "an empty ago phrase is omitted",
  time.from_strings("2025-08-03", "") == "Aug 3 2025",
  time.from_strings("2025-08-03", "")
)
check(
  "a two-digit day has no leading zero",
  time.from_strings("2025-08-13", nil) == "Aug 13 2025",
  time.from_strings("2025-08-13", nil)
)
check(
  "a day past the end of February is empty",
  time.from_strings("2025-02-31", "6 months ago") == "",
  time.from_strings("2025-02-31", "6 months ago")
)
check(
  "February 29 is accepted in a leap year",
  time.from_strings("2024-02-29", "2 years ago") == "Feb 29 2024 (2 years ago)",
  time.from_strings("2024-02-29", "2 years ago")
)
check(
  "malformed iso is empty",
  time.from_strings("not a date", "6 months ago") == "",
  time.from_strings("not a date", "6 months ago")
)
check(
  "a non-string iso is empty",
  time.from_strings(nil, "6 months ago") == "",
  tostring(time.from_strings(nil, "6 months ago"))
)

-- ---------------------------------------------------------------------------
section("time nil handling")

check("relative(nil) is empty", time.relative(nil) == "", time.relative(nil))
check("relative of a non-number is empty", time.relative("2025-08-03") == "", time.relative("2025-08-03"))
check("absolute(nil) is empty", time.absolute(nil) == "", time.absolute(nil))
check("absolute of a non-number is empty", time.absolute({}) == "", time.absolute({}))
check("label(nil) is empty", time.label(nil) == "", time.label(nil))

-- ---------------------------------------------------------------------------
print(("\n== %d passed, %d failed =="):format(pass, fail))
vim.cmd(fail == 0 and "qall!" or "cquit!")
