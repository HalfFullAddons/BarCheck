-- Bar Check: saves a character snapshot on logout / reload and shows it as a progress card.
-- /barcheck or /bc = your card. /bc <name> = a saved character. Minimap button too.

local DB_VERSION = 1

local frame = CreateFrame("Frame")
local state = { playedTotal = nil, playedLevel = nil, playedAt = nil, chatFrames = nil }

local unpack = table.unpack or unpack

local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if r[1] then return unpack(r, 2, 12) end
    return nil
end

local function now()
    return (type(time) == "function") and time() or 0
end

-- ---------- tiny JSON encoder (for the /barcheck copy string) ----------
local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end

local function esc(s)
    s = tostring(s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return s
end

local function encode(v)
    local t = type(v)
    if t == "table" then
        local out = {}
        if isArray(v) then
            for i = 1, #v do out[#out + 1] = encode(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local val = v[k]
            if val == nil then val = v[tonumber(k)] end
            out[#out + 1] = '"' .. esc(k) .. '":' .. encode(val)
        end
        return "{" .. table.concat(out, ",") .. "}"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif v == nil then
        return "null"
    end
    return '"' .. esc(v) .. '"'
end

-- ---------- data collectors (every one is safe if the API is missing) ----------
local function collectIdentity()
    local id = {}
    id.name = try(UnitName, "player")
    id.fullName = try(UnitFullName, "player")
    id.unitName = try(GetUnitName, "player", true)
    id.surname = try(UnitSurname, "player")
    id.realm = try(GetRealmName)
    local raceName, raceToken = try(UnitRace, "player")
    id.race, id.raceToken = raceName, raceToken
    local className, classToken = try(UnitClass, "player")
    id.class, id.classToken = className, classToken
    id.faction = try(UnitFactionGroup, "player")
    id.sex = try(UnitSex, "player")
    id.guid = try(UnitGUID, "player")
    id.guild = try(GetGuildInfo, "player")
    return id
end

local function collectProfessions()
    local out = {}
    if type(GetProfessions) == "function" then
        for i = 1, 6 do
            local idx = select(i, GetProfessions())
            if idx then
                local name, _, rank, maxRank = try(GetProfessionInfo, idx)
                if name then out[#out + 1] = { name = name, rank = rank, max = maxRank } end
            end
        end
        if #out > 0 then return out end
    end
    if type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function" then
        local n = try(GetNumSkillLines) or 0
        local header
        for i = 1, n do
            local name, isHeader, _, rank, _, _, maxRank = try(GetSkillLineInfo, i)
            if name then
                if isHeader then
                    header = name
                elseif maxRank and maxRank > 1 then
                    out[#out + 1] = { name = name, rank = rank, max = maxRank, header = header }
                end
            end
        end
    end
    return out
end

local function countCompletedQuests()
    if C_QuestLog and type(C_QuestLog.GetAllCompletedQuestIDs) == "function" then
        local ids = try(C_QuestLog.GetAllCompletedQuestIDs)
        if type(ids) == "table" then return #ids end
    end
    if type(GetQuestsCompleted) == "function" then
        local t = try(GetQuestsCompleted)
        if type(t) == "table" then
            local n = 0
            for _ in pairs(t) do n = n + 1 end
            return n
        end
    end
    return nil
end

local function stat(id)
    local v = try(GetStatistic, id)
    if v == nil then return nil end
    return tonumber((tostring(v):gsub(",", "")))
end

local function counters(guid)
    BarCheckDB.counters = BarCheckDB.counters or {}
    local c = BarCheckDB.counters[guid or "unknown"]
    if not c then
        c = { deaths = 0, kills = 0, quests = 0, since = now() }
        BarCheckDB.counters[guid or "unknown"] = c
    end
    return c
end

local function liveSeconds()
    if state.playedAt and type(GetTime) == "function" then
        return math.floor(GetTime() - state.playedAt)
    end
    return 0
end

local function buildSnapshot()
    local s = { v = DB_VERSION, t = now() }
    local id = collectIdentity()
    s.id = id
    s.level = try(UnitLevel, "player")
    s.xp = try(UnitXP, "player")
    s.xpMax = try(UnitXPMax, "player")
    s.rested = try(GetXPExhaustion)
    s.zone = try(GetRealZoneText) or try(GetZoneText)
    s.subzone = try(GetSubZoneText)
    local ilvlAll, ilvlEq = try(GetAverageItemLevel)
    s.ilvl = ilvlEq or ilvlAll
    s.money = try(GetMoney)
    s.professions = collectProfessions()

    if state.playedTotal then
        s.playedTotal = state.playedTotal + liveSeconds()
        s.playedLevel = state.playedLevel and (state.playedLevel + liveSeconds()) or nil
    end

    local c = counters(id.guid)
    -- counters only count from install day, so a zero means "unknown", not "none"
    s.deaths = stat(60) or (c.deaths > 0 and c.deaths or nil)
    s.kills = stat(1197) or (c.kills > 0 and c.kills or nil)
    s.quests = countCompletedQuests() or stat(98) or (c.quests > 0 and c.quests or nil)
    s.counted = { deaths = c.deaths, kills = c.kills, since = c.since }
    s.build = { try(GetBuildInfo) }
    return s
end

local function displayName(s)
    local who = s.id.unitName or s.id.fullName or s.id.name or "Unknown"
    if s.id.surname and s.id.surname ~= "" and not tostring(who):find(s.id.surname, 1, true) then
        who = who .. " " .. s.id.surname
    end
    return who
end

local function snapshotKey(s)
    local who = s.id.unitName or s.id.fullName or s.id.name or "Unknown"
    if s.id.surname and s.id.surname ~= "" and not tostring(who):find(s.id.surname, 1, true) then
        who = who .. " " .. s.id.surname
    end
    return who .. "-" .. tostring(s.id.realm or "")
end

local function save()
    BarCheckDB = BarCheckDB or {}
    BarCheckDB.version = DB_VERSION
    BarCheckDB.characters = BarCheckDB.characters or {}
    local ok, snap = pcall(buildSnapshot)
    if ok and snap and snap.level then
        snap.display = displayName(snap)
        local key = snapshotKey(snap)
        BarCheckDB.characters[key] = snap
        BarCheckDB.last = key
    end
end

-- ---------- time played (without chat spam) ----------
local function restoreChat()
    if state.chatFrames then
        for _, cf in ipairs(state.chatFrames) do cf:RegisterEvent("TIME_PLAYED_MSG") end
        state.chatFrames = nil
    end
end

local function requestPlayed()
    if type(RequestTimePlayed) ~= "function" then return end
    state.chatFrames = {}
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local cf = _G["ChatFrame" .. i]
        if cf and cf.IsEventRegistered and cf:IsEventRegistered("TIME_PLAYED_MSG") then
            cf:UnregisterEvent("TIME_PLAYED_MSG")
            state.chatFrames[#state.chatFrames + 1] = cf
        end
    end
    pcall(RequestTimePlayed)
    if C_Timer and C_Timer.After then C_Timer.After(5, restoreChat) else restoreChat() end
end


-- =====================================================================
-- Card UI. art\bg_<race>.tga is the picture, art\over_<faction>.tga is the themed
-- picture frame + static ornaments on top of it. Everything that changes (all text,
-- XP segments, banners) is drawn live. Coordinates are in "picture pixels"
-- (1200 x 700, y measured from the top); the frame band adds OFF pixels on every side.
-- =====================================================================
local ADDON_DIR = "Interface\\AddOns\\BarCheck\\"
local ART = ADDON_DIR .. "art\\"
local FONT_B = ADDON_DIR .. "fonts\\Cinzel_700Bold.ttf"
local FONT_S = ADDON_DIR .. "fonts\\Cinzel_600SemiBold.ttf"
local FONT_I = ADDON_DIR .. "fonts\\LiberationSerif-Italic.ttf"

local CARD_W, CARD_H = 1200, 700
local OFF = 32
local FULL_W, FULL_H = CARD_W + 2 * OFF, CARD_H + 2 * OFF
local BANNER_W, BANNER_H, BANNER_GAP, BANNER_Y, BANNER_TEXT_W = 196, 210, 10, 376, 106
local STRIP_Y, FOOT_Y = 596, 667
local NA = "N/A"
local STALE_AFTER = 24 * 3600

local FACTION_OF = {
    human = "Alliance", dwarf = "Alliance", night_elf = "Alliance", gnome = "Alliance", skyborne = "Alliance",
    orc = "Horde", undead = "Horde", tauren = "Horde", troll = "Horde",
}
local THEME = {
    Alliance = { accent = { 240, 200, 96 }, accent2 = { 196, 214, 255 }, text = { 238, 242, 255 } },
    Horde = { accent = { 226, 128, 70 }, accent2 = { 236, 188, 140 }, text = { 250, 230, 214 } },
}
local RACE_TINT = {
    night_elf = { 176, 150, 255 }, undead = { 150, 206, 120 }, troll = { 70, 206, 176 }, gnome = { 255, 168, 70 },
    tauren = { 222, 170, 96 }, skyborne = { 255, 236, 170 }, dwarf = { 214, 146, 64 },
}
local CON = {
    red = "CHALLENGING", orange = "TOUGH", yellow = "FAIR", green = "EASY", grey = "OUTLEVELED",
}
local CON_ORDER = { green = 0, yellow = 1, orange = 2, red = 3, grey = 4 }
local KNOWN_CLASS = { warrior = 1, paladin = 1, hunter = 1, rogue = 1, priest = 1, shaman = 1, mage = 1, warlock = 1, druid = 1 }

-- ---------- formatting helpers ----------
local function commas(n)
    local s = tostring(math.floor(n + 0.5))
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
end

local function fmtInt(n)
    if type(n) ~= "number" then return NA end
    return commas(n)
end

local function fmtPlayed(sec)
    if type(sec) ~= "number" then return NA end
    local d = math.floor(sec / 86400)
    local h = math.floor((sec % 86400) / 3600)
    local m = math.floor((sec % 3600) / 60)
    if d > 0 then return d .. "d " .. h .. "h" end
    if h > 0 then return h .. "h " .. m .. "m" end
    return m .. "m"
end

local function fmtGold(copper)
    if type(copper) ~= "number" then return NA end
    copper = math.floor(copper)
    local g, sv, cp = math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100
    return "|cffffd700" .. commas(g) .. "g|r |cffd0d0d8" .. sv .. "s|r |cffe8a266" .. cp .. "c|r"
end
local function stripColors(t) return (tostring(t):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

-- ---------- settings and the stats that can appear in the strip ----------
local STAT_POOL = {
    { key = "ilvl", label = "ITEM LEVEL" },
    { key = "deaths", label = "DEATHS" },
    { key = "time", label = "TIME PLAYED" },
    { key = "quests", label = "QUESTS" },
    { key = "kills", label = "KILLS" },
    { key = "gold", label = "GOLD" },
}
local DEFAULT_SETTINGS = {
    animate = true, fast = false, shout = true, scale = 100,
    minimap = true, showGuild = false, versionCheck = true,
    stats = { ilvl = true, deaths = true, time = true, quests = true, kills = true, gold = false },
}

local function opt()
    BarCheckDB = BarCheckDB or {}
    local o = BarCheckDB.settings
    if type(o) ~= "table" then o = {}; BarCheckDB.settings = o end
    for k, v in pairs(DEFAULT_SETTINGS) do
        if k ~= "stats" and o[k] == nil then o[k] = v end
    end
    if type(o.stats) ~= "table" then o.stats = {} end
    local any = false
    for _, e in ipairs(STAT_POOL) do
        if o.stats[e.key] == nil then o.stats[e.key] = DEFAULT_SETTINGS.stats[e.key] end
        if o.stats[e.key] then any = true end
    end
    if not any then o.stats.ilvl = true end
    return o
end

-- the strip grows to extra rows when many stats are picked (up to 5 per row)
local STRIP_BOTTOM, ROW_H, PER_ROW_MAX = 646, 50, 5
local function stripLayout(n)
    n = math.max(n, 1)
    local rows = math.ceil(n / PER_ROW_MAX)
    return rows, math.ceil(n / rows), STRIP_BOTTOM - ROW_H * rows
end

local function selectedStats()
    local o, out = opt(), {}
    for _, e in ipairs(STAT_POOL) do
        if o.stats[e.key] then out[#out + 1] = e.key end
    end
    return out
end

local STAT_LABEL = {}
for _, e in ipairs(STAT_POOL) do STAT_LABEL[e.key] = e.label end

-- text and raw number for one stat of a snapshot
local function statValue(kind, s)
    if kind == "ilvl" then
        local v = s.ilvl and math.floor(s.ilvl + 0.5) or nil
        return fmtInt(v), v
    elseif kind == "deaths" then local v = tonumber(s.deaths); return fmtInt(v), v
    elseif kind == "time" then local v = tonumber(s.playedTotal); return fmtPlayed(v), v
    elseif kind == "quests" then local v = tonumber(s.quests); return fmtInt(v), v
    elseif kind == "kills" then local v = tonumber(s.kills); return fmtInt(v), v
    elseif kind == "gold" then
        local m = tonumber(s.money)
        return fmtGold(m), m
    end
    return NA, nil
end

local function conOf(level, lo, hi)
    if level < lo then return "red" end
    if level > hi then return "grey" end
    local p = (level - lo) / math.max(1, hi - lo)
    if p < 0.25 then return "orange" elseif p < 0.75 then return "yellow" end
    return "green"
end

local function pickDungeons(level)
    local items = {}
    for _, d in ipairs(BarCheckDungeons or {}) do
        local c = conOf(level, d.lo, d.hi)
        if not (c == "red" and d.lo - level > 2) then
            items[#items + 1] = { d = d, c = c }
        end
    end
    table.sort(items, function(a, b)
        local oa, ob = CON_ORDER[a.c], CON_ORDER[b.c]
        if oa ~= ob then return oa < ob end
        return a.d.lo < b.d.lo
    end)
    while #items > 5 do table.remove(items) end
    return items
end

-- the game may report sub-races or variants ("Windshaper Skyborne", "Dark Iron Dwarf"), so match
-- on the base race name rather than the exact text
local RACE_ORDER = { "night_elf", "skyborne", "human", "dwarf", "gnome", "undead", "tauren", "troll", "orc" }
local RACE_ALIAS = { nightelf = "night_elf", scourge = "undead", forsaken = "undead" }
local function raceKey(s)
    local id = s.id or {}
    local first
    for _, src in ipairs({ id.raceToken or "", id.race or "" }) do
        local r = (tostring(src):lower():gsub("[%s%-]+", "_"))
        if r ~= "" then
            first = first or r
            if RACE_ALIAS[r] then return RACE_ALIAS[r] end
            for _, key in ipairs(RACE_ORDER) do
                if r == key or r:find(key, 1, true) then return key end
            end
            for alias, key in pairs(RACE_ALIAS) do
                if r:find(alias, 1, true) then return key end
            end
        end
    end
    return first or ""
end

-- ---------- frame construction ----------
local card, pic
local ui = {}

local function color(t, a) return t[1] / 255, t[2] / 255, t[3] / 255, a or 1 end

-- Cinzel only covers Latin letters, so Russian, Korean and Chinese clients use the game's own font
local LOCALE = (type(GetLocale) == "function" and GetLocale()) or "enUS"
local NON_LATIN = { ruRU = true, koKR = true, zhCN = true, zhTW = true }
local function setFont(fs, path, size, flags)
    if NON_LATIN[LOCALE] and STANDARD_TEXT_FONT then path = STANDARD_TEXT_FONT end
    local ok = fs:SetFont(path, size, flags or "")
    if not ok then fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, flags or "") end
end

local function newText(parent, path, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    setFont(fs, path, size)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetShadowColor(0, 0, 0, 0.9)
    fs:SetShadowOffset(1.5, -1.5)
    return fs
end

local function put(obj, point, x, y)
    obj:ClearAllPoints()
    obj:SetPoint(point, pic, "TOPLEFT", math.floor(x + 0.5), -math.floor(y + 0.5))
end

local function solid(parent, layer, sub, r, g, b, a)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    if t.SetColorTexture then t:SetColorTexture(r, g, b, a or 1) else t:SetTexture(r, g, b, a or 1) end
    return t
end

local BX, BW = 70, 1060
local SCALE_X = BW / 2200
local LX0, LX1 = BX + 92 * SCALE_X, BX + (2200 - 92) * SCALE_X   -- text labels line up with these
-- bar segments run under the whole frame opening; the frame texture is drawn on top
local IX0, IX1 = BX + 40 * SCALE_X, BX + 2160 * SCALE_X
local IY0, IY1 = 252 + 30 * SCALE_X, 252 + 160 * SCALE_X
local SEGW = (IX1 - IX0) / 20

local function setBars(bars, rested)
    for i, seg in ipairs(ui.seg) do
        local fr = math.max(0, math.min(1, bars - (i - 1)))
        local rr = math.max(0, math.min(1, bars + rested - (i - 1)))
        if rr > 0 then seg.rest:SetWidth(math.max(0.5, seg.w * rr)); seg.rest:Show() else seg.rest:Hide() end
        if fr > 0 then
            seg.fill:SetWidth(math.max(0.5, seg.w * fr)); seg.fill:Show()
            seg.hi:SetWidth(math.max(0.5, seg.w * fr)); seg.hi:Show()
        else
            seg.fill:Hide(); seg.hi:Hide()
        end
    end
end
ui.setBars = setBars

local function build()
    card = CreateFrame("Frame", "BarCheckCard", UIParent)
    card:SetSize(FULL_W, FULL_H)
    card:SetPoint("CENTER")
    card:SetFrameStrata("DIALOG")
    card:SetClampedToScreen(true)
    card:EnableMouse(true)
    card:SetMovable(true)
    card:RegisterForDrag("LeftButton")
    card:SetScript("OnDragStart", card.StartMoving)
    card:SetScript("OnDragStop", card.StopMovingOrSizing)
    card:SetScript("OnMouseDown", function() if BarCheck_SkipAnim then BarCheck_SkipAnim() end end)
    card:SetScript("OnHide", function() if BarCheck_StopAnim then BarCheck_StopAnim() end end)
    card:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, "BarCheckCard") end

    pic = CreateFrame("Frame", "BarCheckPic", card)
    pic:SetSize(CARD_W, CARD_H)
    pic:SetPoint("TOPLEFT", card, "TOPLEFT", OFF, -OFF)

    ui.bg = card:CreateTexture(nil, "BACKGROUND", nil, 0)
    ui.bg:SetAllPoints(pic)
    ui.over = card:CreateTexture(nil, "BACKGROUND", nil, 1)
    ui.over:SetAllPoints(card)
    ui.motif = card:CreateTexture(nil, "ARTWORK", nil, 5)
    ui.motif:SetSize(62, 62)
    ui.levelLbl = newText(card, FONT_B, 15, "CENTER")
    ui.heading = newText(card, FONT_B, 17, "CENTER")
    ui.credit = newText(card, FONT_I, 13, "RIGHT")
    ui.statLbl = {}

    -- level + name block
    ui.level = newText(card, FONT_B, 66, "CENTER")
    ui.level:SetShadowOffset(3, -3)
    ui.name = newText(card, FONT_B, 58, "LEFT")
    ui.name:SetShadowOffset(3, -3)
    ui.classIcon = card:CreateTexture(nil, "ARTWORK")
    ui.classIcon:SetSize(46, 46)
    ui.raceClass = newText(card, FONT_B, 24, "LEFT")
    ui.zone = newText(card, FONT_I, 24, "LEFT")
    ui.guild = newText(card, FONT_I, 22, "RIGHT")
    ui.guild:SetWidth(380)
    if ui.guild.SetWordWrap then ui.guild:SetWordWrap(false) end
    ui.profs = newText(card, FONT_B, 21, "LEFT")

    -- xp bar segments
    ui.seg = {}
    for i = 1, 20 do
        local x0 = IX0 + (i - 1) * SEGW + 2.5
        local x1 = IX0 + i * SEGW - 2.5
        local h = IY1 - IY0 - 6
        local seg = { x0 = x0, x1 = x1, w = x1 - x0 }
        seg.rest = solid(card, "ARTWORK", 1, 70 / 255, 104 / 255, 170 / 255)
        seg.fill = solid(card, "ARTWORK", 2, 126 / 255, 52 / 255, 178 / 255)
        seg.hi = solid(card, "ARTWORK", 3, 170 / 255, 104 / 255, 220 / 255)
        for _, t in ipairs({ seg.rest, seg.fill }) do
            t:SetHeight(h)
            t:SetPoint("TOPLEFT", pic, "TOPLEFT", x0, -(IY0 + 3))
        end
        seg.hi:SetHeight((IY1 - IY0) * 0.38 - 3)
        seg.hi:SetPoint("TOPLEFT", pic, "TOPLEFT", x0, -(IY0 + 3))
        seg.rest:Hide(); seg.fill:Hide(); seg.hi:Hide()
        ui.seg[i] = seg
    end
    ui.xpframe = card:CreateTexture(nil, "OVERLAY", nil, 4)
    ui.xpframe:SetSize(BW, BW * 190 / 2200)
    ui.xpframe:SetPoint("TOPLEFT", pic, "TOPLEFT", BX, -252)
    ui.xpframe:SetTexCoord(0, 1, 0, (2048 * 190 / 2200) / 256)
    ui.spark = card:CreateTexture(nil, "OVERLAY", nil, 6)
    ui.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    ui.spark:SetBlendMode("ADD")
    ui.spark:SetSize(34, (IY1 - IY0) * 2.2)
    ui.spark:Hide()
    ui.flash = card:CreateTexture(nil, "OVERLAY", nil, 5)
    ui.flash:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    ui.flash:SetBlendMode("ADD")
    ui.flash:SetSize(300, 300)
    ui.flash:SetPoint("CENTER", pic, "TOPLEFT", 133, -139)
    ui.flash:SetAlpha(0)
    ui.barsIn = newText(card, FONT_B, 22, "LEFT")
    ui.toNext = newText(card, FONT_S, 17, "RIGHT")

    -- banners
    ui.banner = {}
    for i = 1, 5 do
        local b = {}
        b.f = CreateFrame("Frame", nil, card)
        b.f:SetSize(BANNER_W, BANNER_H)
        b.f:SetFrameLevel(card:GetFrameLevel() + 2)
        b.tex = b.f:CreateTexture(nil, "ARTWORK", nil, 4)
        b.tex:SetSize(BANNER_W, BANNER_H)
        b.tex:SetPoint("TOPLEFT", b.f, "TOPLEFT", 0, 0)
        b.land = newText(b.f, FONT_S, 9, "CENTER")
        b.name = newText(b.f, FONT_B, 18, "CENTER")
        b.name:SetWidth(BANNER_TEXT_W)
        b.name:SetSpacing(0)
        b.range = newText(b.f, FONT_B, 30, "CENTER")
        b.note = newText(b.f, FONT_I, 16, "CENTER")
        b.tag = newText(b.f, FONT_S, 11, "CENTER")
        for _, fs in ipairs({ b.land, b.name, b.range, b.note, b.tag }) do fs:SetShadowOffset(0, 0); fs:SetShadowColor(0, 0, 0, 0) end
        for _, fs in ipairs({ b.land, b.name, b.range, b.note, b.tag }) do
            fs:SetShadowOffset(0, 0)
            fs:SetDrawLayer("OVERLAY", 7)
        end
        ui.banner[i] = b
    end
    ui.noDungeons = newText(card, FONT_I, 26, "CENTER")

    -- stats strip
    ui.stat, ui.statIcon, ui.divider = {}, {}, {}
    ui.panel = {}
    for i = 1, 9 do ui.panel[i] = card:CreateTexture(nil, "ARTWORK", nil, 3) end
    ui.rowDiv = {}
    for i = 1, 4 do ui.rowDiv[i] = card:CreateTexture(nil, "ARTWORK", nil, 4) end
    ui.ensureStat = function(i)
        if ui.stat[i] then return end
        ui.stat[i] = newText(card, FONT_B, 25, "LEFT")
        ui.statLbl[i] = newText(card, FONT_S, 12, "LEFT")
        ui.statIcon[i] = card:CreateTexture(nil, "ARTWORK", nil, 4)
        ui.statIcon[i]:SetSize(38, 38)
        ui.divider[i] = card:CreateTexture(nil, "ARTWORK", nil, 4)
    end
    for i = 1, 5 do ui.ensureStat(i) end

    -- footer
    ui.stamp = newText(card, FONT_S, 13, "LEFT")

    -- toolbar across the top of the card (background + outline), with the close button at its right end
    local bar = CreateFrame("Frame", "BarCheckToolbar", card, BackdropTemplateMixin and "BackdropTemplate" or nil)
    bar:SetSize(FULL_W, 34)
    bar:SetPoint("BOTTOMLEFT", card, "TOPLEFT", 0, 3)
    if bar.SetBackdrop then
        bar:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        if bar.SetBackdropBorderColor then bar:SetBackdropBorderColor(0.9, 0.75, 0.35, 1) end
    end
    local barShade = bar:CreateTexture(nil, "BACKGROUND", nil, 1)
    barShade:SetPoint("TOPLEFT", 3, -3)
    barShade:SetPoint("BOTTOMRIGHT", -3, 3)
    if barShade.SetColorTexture then barShade:SetColorTexture(0.03, 0.03, 0.06, 0.85) end
    ui.toolbar = bar
    local close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
    close:SetSize(28, 28)
    close:SetPoint("RIGHT", bar, "RIGHT", -3, 0)
    close:SetScript("OnClick", function() card:Hide() end)
    ui.hint = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.hint:SetPoint("TOP", card, "BOTTOM", 0, -4)
    ui.hint:SetText("Snip it with your snipping tool and paste it into Discord. Esc closes. Drag to move.")

    local function mkBtn(label, w, x, handler)
        local b = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        b:SetPoint("LEFT", bar, "LEFT", x, 0)
        b:SetText(label)
        b:SetScript("OnClick", handler)
        return b
    end
    ui.charBtn = mkBtn("Characters", 100, 8, function() if BarCheck_ShowChars then BarCheck_ShowChars() end end)
    ui.shoutBtn = mkBtn("Bar Check!", 90, 112, function() if BarCheck_Shout then BarCheck_Shout() end end)
    ui.optBtn = mkBtn("Options", 74, 206, function() if BarCheck_Options then BarCheck_Options() end end)
    ui.copyBtn = mkBtn("Copy Text", 84, 284, function() if BarCheck_CopyText then BarCheck_CopyText() end end)
end

-- ---------- fill the card from a snapshot ----------
local function fill(s)
    local id = s.id or {}
    for _, o in ipairs({ ui.name, ui.raceClass, ui.classIcon, ui.zone, ui.profs, ui.barsIn, ui.toNext, ui.stamp, ui.level, ui.guild }) do o:SetAlpha(1) end
    for i = 1, #ui.stat do ui.stat[i]:SetAlpha(1) end
    ui.spark:Hide(); ui.flash:SetAlpha(0)
    local rk = raceKey(s)
    local faction = id.faction
    if faction ~= "Horde" and faction ~= "Alliance" then faction = FACTION_OF[rk] or "Alliance" end
    local th = THEME[faction]
    local accent, accent2, text = th.accent, RACE_TINT[rk] or th.accent2, th.text
    local baseRace = FACTION_OF[rk] and rk or (faction == "Horde" and "orc" or "human")
    ui.bg:SetTexture(ART .. "bg_" .. baseRace .. ".tga")
    ui.over:SetTexture(ART .. "over_" .. faction:lower() .. ".tga")
    ui.motif:Hide()
    ui.xpframe:SetTexture(ART .. "xpframe_" .. faction:lower() .. ".tga")
    ui.levelLbl:SetText("LEVEL"); ui.levelLbl:SetTextColor(color(accent)); put(ui.levelLbl, "CENTER", 133, 97)
    ui.heading:SetText("BAR CHECK"); ui.heading:SetTextColor(accent[1] / 255 * 0.9, accent[2] / 255 * 0.9, accent[3] / 255 * 0.9)
    put(ui.heading, "CENTER", CARD_W / 2, FOOT_Y)
    ui.credit:SetText("Unofficial fan tool. World of Warcraft is a trademark of Blizzard Entertainment.")
    ui.credit:SetTextColor(text[1] / 255 * 0.75, text[2] / 255 * 0.75, text[3] / 255 * 0.75)
    put(ui.credit, "RIGHT", CARD_W - 66, FOOT_Y)

    local level = tonumber(s.level) or 1
    ui.level:SetText(tostring(level))
    setFont(ui.level, FONT_B, level >= 100 and 52 or 66)
    ui.level:SetTextColor(color(text))
    put(ui.level, "CENTER", 133, 149)

    -- name (shrink to fit)
    local nm = s.display or id.unitName or id.name or "Unknown Adventurer"
    ui.name:SetText(nm)
    local size = 58
    setFont(ui.name, FONT_B, size)
    while size > 28 and ui.name:GetStringWidth() > 730 do
        size = size - 2
        setFont(ui.name, FONT_B, size)
    end
    ui.name:SetTextColor(color(text))
    put(ui.name, "LEFT", 276, 86)

    -- class icon, race + class
    local ck = (id.classToken or ""):lower()
    local tx = 278
    if KNOWN_CLASS[ck] then
        ui.classIcon:SetTexture(ART .. "class_" .. ck .. ".tga")
        ui.classIcon:Show()
        ui.classIcon:ClearAllPoints()
        ui.classIcon:SetPoint("CENTER", pic, "TOPLEFT", 296, -146)
        tx = 328
    else
        ui.classIcon:Hide()
    end
    local rc = ((id.race or "") .. " " .. (id.class or "")):upper():gsub("^%s+", "")
    if rc == "" then rc = NA end
    ui.raceClass:SetText(rc)
    ui.raceClass:SetTextColor(color(accent))
    put(ui.raceClass, "LEFT", tx, 146)
    if opt().showGuild and id.guild and id.guild ~= "" then
        ui.guild:SetText("<" .. id.guild .. ">")
        ui.guild:SetTextColor(color(accent2))
        put(ui.guild, "RIGHT", 1120, 146)
        ui.guild:Show()
    else
        ui.guild:Hide()
    end

    local zline
    if s.zone and s.zone ~= "" then
        zline = "Adventuring in " .. s.zone
        if s.subzone and s.subzone ~= "" and s.subzone ~= s.zone then zline = zline .. " - " .. s.subzone end
    else
        zline = "Adventuring somewhere in Azeroth"
    end
    ui.zone:SetText(zline)
    ui.zone:SetTextColor(color(accent2))
    put(ui.zone, "LEFT", 278, 196)

    local pt = {}
    for _, p in ipairs(s.professions or {}) do
        if #pt < 6 and p.name then pt[#pt + 1] = p.name .. " " .. tostring(p.rank or "?") .. "/" .. tostring(p.max or "?") end
    end
    local psz = 21
    ui.profs:SetText(table.concat(pt, #pt > 3 and "  ||  " or "   ||   "))
    setFont(ui.profs, FONT_B, psz)
    while psz > 13 and (ui.profs:GetStringWidth() or 0) > 880 do
        psz = psz - 1
        setFont(ui.profs, FONT_B, psz)
    end
    ui.profs:SetTextColor(color(accent))
    put(ui.profs, "LEFT", 278, 240)

    -- xp bar
    local xp, xpMax = tonumber(s.xp), tonumber(s.xpMax)
    local xpOK = xp and xpMax and xpMax > 0
    local frac = xpOK and math.max(0, math.min(0.9999, xp / xpMax)) or 0
    local bars = frac * 20
    local rested = 0
    if xpOK and tonumber(s.rested) then rested = tonumber(s.rested) / xpMax * 20 end
    ui.setBars(bars, rested)
    ui.model = { level = level, bars = bars, rested = rested, xpOK = xpOK,
        raw = {}, kinds = {} }
    ui.shoutBtn[opt().shout and "Show" or "Hide"](ui.shoutBtn)
    if xpOK then
        ui.barsIn:SetText(math.floor(bars) .. " BARS IN")
        ui.toNext:SetText(math.floor(frac * 100 + 0.5) .. "% TO LEVEL " .. (level + 1) .. (rested > 0 and "   .   RESTED" or ""))
    else
        ui.barsIn:SetText("XP  " .. NA)
        ui.toNext:SetText("LEVEL " .. level)
    end
    ui.barsIn:SetTextColor(color(accent)); put(ui.barsIn, "LEFT", LX0, 362)
    ui.toNext:SetTextColor(color(text)); put(ui.toNext, "RIGHT", LX1, 362)

    -- dungeons within reach
    for _, b in ipairs(ui.banner) do
        b.f:Hide(); b.f:SetAlpha(1); b.land:SetText(""); b.name:SetText(""); b.range:SetText(""); b.note:SetText(""); b.tag:SetText("")
    end
    local items = pickDungeons(level)
    ui.nBanners = #items
    ui.noDungeons:SetText(#items == 0 and "No dungeons in range right now - keep adventuring!" or "")
    ui.noDungeons:SetTextColor(color(text)); put(ui.noDungeons, "CENTER", 600, 470)
    local bw, bh, gap, by = BANNER_W, BANNER_H, BANNER_GAP, BANNER_Y
    local _, _, stripTop = stripLayout(#selectedStats())
    local bsc = math.max(0.5, math.min(1, (stripTop - 10 - by) / bh))
    local total = (#items * bw + (#items - 1) * gap) * bsc
    local x = (CARD_W - total) / 2
    local dark = { 46 / 255, 30 / 255, 18 / 255 }
    for i, it in ipairs(items) do
        local b, d, c = ui.banner[i], it.d, it.c
        b.tex:SetTexture(ART .. "banner_" .. faction:lower() .. "_" .. c .. ".tga")
        b.x, b.y, b.sc = x, by, bsc
        b.f:SetScale(bsc)
        b.f:ClearAllPoints(); b.f:SetPoint("TOPLEFT", pic, "TOPLEFT", x / bsc, -by / bsc); b.f:Show()
        local function putB(obj, point, dx, dy)
            obj:ClearAllPoints(); obj:SetPoint(point, b.f, "TOPLEFT", dx, -dy)
        end
        local cx = bw / 2 - 1
        local cy, nsz = 70, 18
        if d.home and d.home ~= faction then
            b.land:SetText(d.home:upper() .. " NATIVES"); b.land:SetTextColor(120 / 255, 40 / 255, 24 / 255)
            putB(b.land, "CENTER", cx, 49)
            cy, nsz = 79, 16
        else
            b.land:SetText("")
        end
        b.name:SetText(d.name); b.name:SetTextColor(unpack(dark))
        setFont(b.name, FONT_B, nsz)
        b.name:SetWidth(BANNER_TEXT_W)
        while nsz > 11 and (b.name:GetStringWidth() > BANNER_TEXT_W + 0.5 or ((b.name.GetNumLines and tonumber(b.name:GetNumLines()) or 1) > 2)) do
            nsz = nsz - 1
            setFont(b.name, FONT_B, nsz)
        end
        b.name:ClearAllPoints(); b.name:SetPoint("CENTER", b.f, "TOPLEFT", cx, -cy)
        local ry = 119
        b.range:SetText(d.lo .. "-" .. d.hi); b.range:SetTextColor(unpack(dark)); putB(b.range, "CENTER", cx, ry)
        local note
        if level >= d.lo and level <= d.hi then
            note = "you are in range"
        elseif level < d.lo then
            local n = d.lo - level
            note = n .. " level" .. (n > 1 and "s" or "") .. " to go"
        else
            note = "long outleveled"
        end
        b.note:SetText(note); b.note:SetTextColor(70 / 255, 46 / 255, 26 / 255); putB(b.note, "CENTER", cx, ry + 26)
        b.tag:SetText(CON[c]); b.tag:SetTextColor(unpack(dark)); putB(b.tag, "CENTER", cx, ry + 45)
        x = x + (bw + gap) * bsc
    end

    -- stats strip: every stat chosen in the settings, in as many rows as needed
    local sel = selectedStats()
    local n = #sel
    local rows, per, top = stripLayout(n)
    ui.model.nStats = n
    -- panel (9-slice: corners stay sharp, edges stretch)
    local PX0, PX1, PY0, PY1, CS = 60, 1140, top, STRIP_BOTTOM, 16
    local cols = { { PX0, CS, 0, 0.125 }, { PX0 + CS, (PX1 - PX0) - 2 * CS, 0.125, 0.875 }, { PX1 - CS, CS, 0.875, 1 } }
    local rws = { { PY0, CS, 0, 0.125 }, { PY0 + CS, (PY1 - PY0) - 2 * CS, 0.125, 0.875 }, { PY1 - CS, CS, 0.875, 1 } }
    local pi = 0
    for r = 1, 3 do
        for c = 1, 3 do
            pi = pi + 1
            local t = ui.panel[pi]
            t:SetTexture(ART .. "strip_" .. faction:lower() .. ".tga")
            t:SetTexCoord(cols[c][3], cols[c][4], rws[r][3], rws[r][4])
            t:SetSize(cols[c][2], rws[r][2])
            t:ClearAllPoints(); t:SetPoint("TOPLEFT", pic, "TOPLEFT", cols[c][1], -rws[r][1])
            t:Show()
        end
    end
    for k = 1, 4 do
        local rd = ui.rowDiv[k]
        if k < rows then
            rd:SetSize(1040, 1)
            if rd.SetColorTexture then rd:SetColorTexture(accent[1] / 255 * 0.55, accent[2] / 255 * 0.55, accent[3] / 255 * 0.55, 0.9) end
            rd:ClearAllPoints(); rd:SetPoint("TOPLEFT", pic, "TOPLEFT", 80, -(top + k * ROW_H)); rd:Show()
        else
            rd:Hide()
        end
    end
    for i = 1, math.max(n, #ui.stat) do
        if i <= n then ui.ensureStat(i) end
        local kind = sel[i]
        local fs, lb, ic, dv = ui.stat[i], ui.statLbl[i], ui.statIcon[i], ui.divider[i]
        if not kind then
            if fs then fs:Hide(); lb:Hide(); ic:Hide(); dv:Hide() end
        else
            local v, raw = statValue(kind, s)
            ui.model.raw[i], ui.model.kinds[i] = raw, kind
            local row = math.ceil(i / per)
            local inRow = math.min(per, n - (row - 1) * per)
            local col = i - (row - 1) * per - 1
            local colw = 1080 / inRow
            local cx0 = 60 + col * colw
            local y0 = top + (row - 1) * ROW_H
            local isna = v == NA
            local vsz = isna and 19 or 25
            setFont(fs, FONT_B, vsz)
            fs:SetText(v)
            while vsz > 13 and (fs:GetStringWidth() or 0) > colw - 72 do
                vsz = vsz - 1
                setFont(fs, FONT_B, vsz)
            end
            if isna then fs:SetTextColor(text[1] / 255 * 0.55, text[2] / 255 * 0.55, text[3] / 255 * 0.55) else fs:SetTextColor(color(text)) end
            fs:Show(); put(fs, "LEFT", cx0 + 60, y0 + 17)
            lb:SetText(STAT_LABEL[kind]); lb:SetTextColor(color(accent2)); lb:Show()
            put(lb, "LEFT", cx0 + 61, y0 + 38)
            ic:SetTexture(ART .. "stat_" .. kind .. ".tga"); ic:Show()
            ic:ClearAllPoints(); ic:SetPoint("CENTER", pic, "TOPLEFT", math.floor(cx0 + 32 + 0.5), -(y0 + 25))
            if col > 0 then
                dv:SetSize(1, 34)
                if dv.SetColorTexture then dv:SetColorTexture(accent[1] / 255 * 0.55, accent[2] / 255 * 0.55, accent[3] / 255 * 0.55, 0.9) end
                dv:ClearAllPoints(); dv:SetPoint("TOPLEFT", pic, "TOPLEFT", math.floor(cx0 + 0.5), -(y0 + 8)); dv:Show()
            else
                dv:Hide()
            end
        end
    end

    -- footer: when this snapshot was taken
    local stamp = "Snapshot not dated"
    local stale = false
    if tonumber(s.t) and s.t > 0 then
        stamp = "Snapshot: " .. date("%b %d, %I:%M %p", s.t):gsub(" 0", " ")
        stale = (time() - s.t) > STALE_AFTER
    end
    ui.stamp:SetText(stamp)
    if stale then ui.stamp:SetTextColor(1, 176 / 255, 40 / 255) else ui.stamp:SetTextColor(text[1] / 255 * 0.85, text[2] / 255 * 0.85, text[3] / 255 * 0.85) end
    put(ui.stamp, "LEFT", 66, FOOT_Y)
end


-- ---------- build-up animation (about 2.5 s; click the card to skip) ----------
local ANIM_TOTAL = 2.5
local anim

local function span(t, a, b) return math.max(0, math.min(1, (t - a) / (b - a))) end
local function easeOut(x) x = math.max(0, math.min(1, x)); return 1 - (1 - x) ^ 3 end
local function easeBack(x)
    x = math.max(0, math.min(1, x))
    local c1 = 1.70158
    local c3 = c1 + 1
    return 1 + c3 * (x - 1) ^ 3 + c1 * (x - 1) ^ 2
end

local function applyAnim(t)
    local m = ui.model
    if not m then return end
    -- level counts up while the ring flashes
    ui.level:SetText(tostring(math.max(1, math.floor(1 + (m.level - 1) * easeOut(span(t, 0, 1.0)) + 0.5))))
    ui.flash:SetAlpha(math.sin(span(t, 0, 0.9) * math.pi) * 0.9)
    -- name slides in, then class line, then zone and professions
    local na = span(t, 0.1, 0.6)
    ui.name:SetAlpha(na)
    put(ui.name, "LEFT", 276 - 40 * (1 - easeOut(na)), 86)
    local ca = span(t, 0.3, 0.8)
    ui.raceClass:SetAlpha(ca); ui.classIcon:SetAlpha(ca); ui.guild:SetAlpha(ca)
    local za = span(t, 0.45, 0.95)
    ui.zone:SetAlpha(za); ui.profs:SetAlpha(za)
    -- xp bar: purple fills first, then the blue rested bonus is added on top of it
    local bx = easeOut(span(t, 0.4, 1.4))
    local rx = (m.rested or 0) > 0 and easeOut(span(t, 1.4, 2.0)) or 0
    ui.setBars(m.bars * bx, m.rested * rx)
    ui.barsIn:SetAlpha(span(t, 0.4, 0.8))
    if m.xpOK then ui.barsIn:SetText(math.floor(m.bars * bx) .. " BARS IN") end
    ui.toNext:SetAlpha(span(t, 1.5, 2.0))
    local edge
    if m.bars > 0 and bx > 0 and bx < 1 then
        edge = m.bars * bx
    elseif rx > 0 and rx < 1 then
        edge = m.bars + m.rested * rx
    end
    if edge then
        ui.spark:ClearAllPoints()
        ui.spark:SetPoint("CENTER", pic, "TOPLEFT", IX0 + math.min(20, edge) * SEGW, -((IY0 + IY1) / 2))
        ui.spark:SetAlpha(0.9)
        ui.spark:Show()
    else
        ui.spark:Hide()
    end
    -- banners drop in one after another
    for i = 1, (ui.nBanners or 0) do
        local b = ui.banner[i]
        local p = span(t, 1.0 + 0.2 * (i - 1), 1.5 + 0.2 * (i - 1))
        if p <= 0 then
            b.f:Hide()
        else
            b.f:Show()
            b.f:SetAlpha(math.min(1, p * 2.5))
            b.f:ClearAllPoints()
            b.f:SetPoint("TOPLEFT", pic, "TOPLEFT", b.x / (b.sc or 1), -(b.y - (1 - easeBack(p)) * 130) / (b.sc or 1))
        end
    end
    -- stat numbers roll into place
    for i = 1, (m.nStats or 0) do
        local p = span(t, 1.8 + math.min(0.4, 0.1 * (i - 1)), 2.5)
        local raw, kind = m.raw[i], m.kinds and m.kinds[i]
        ui.stat[i]:SetAlpha(math.min(1, p * 4))
        if raw ~= nil then
            local v = raw * easeOut(p)
            ui.stat[i]:SetText(kind == "time" and fmtPlayed(v) or kind == "gold" and fmtGold(v) or fmtInt(math.floor(v + 0.5)))
        end
    end
    ui.stamp:SetAlpha(span(t, 2.0, 2.4))
end

local function stopAnim()
    anim = nil
    if card then card:SetScript("OnUpdate", nil) end
end

local function finishAnim()
    if not anim then return end
    local snap = anim.pending or anim.s
    stopAnim()
    pcall(fill, snap)   -- puts every number, bar and banner into its exact final state
end

local function startAnim(s)
    anim = { t = 0, s = s, speed = opt().fast and 1.7 or 1 }
    applyAnim(0)
    card:SetScript("OnUpdate", function(_, dt)
        if not anim then return end
        anim.t = anim.t + math.min(dt or 0, 0.1) * (anim.speed or 1)
        if anim.t >= ANIM_TOTAL then finishAnim() else applyAnim(anim.t) end
    end)
end

function BarCheck_SkipAnim() finishAnim() end
function BarCheck_StopAnim() stopAnim() end

local shownLive = false
local lastSnap

local function fitToScreen()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    local scale = math.min(1, (sw - 40) / FULL_W, (sh - 90) / FULL_H) * ((opt().scale or 100) / 100)
    if scale <= 0 then scale = 1 end
    card:SetScale(scale)
end

local function showSnapshot(s, live)
    if not card then build() end
    local ok, err = pcall(fill, s)
    if not ok then
        print("|cffff6060Bar Check: could not draw the card (" .. tostring(err) .. ")|r")
        return
    end
    shownLive = live and true or false
    lastSnap = s
    fitToScreen()
    card:Show()
    if opt().animate then startAnim(s) else stopAnim() end
end

-- redraw the current card without the animation (used when a setting changes)
function BarCheck_Rerender()
    if card and card:IsShown() and lastSnap then
        stopAnim()
        pcall(fill, lastSnap)
        fitToScreen()
    end
end

function BarCheck_Refresh()
    if card and card:IsShown() and shownLive then
        local ok, snap = pcall(buildSnapshot)
        if ok and snap and snap.level then
            snap.display = displayName(snap)
            if anim then anim.pending = snap else pcall(fill, snap) end
        end
    end
end

local function liveCard()
    save()
    local snap = BarCheckDB and BarCheckDB.characters and BarCheckDB.last and BarCheckDB.characters[BarCheckDB.last]
    if not snap then
        print("Bar Check: could not read your character yet. Try again in a moment.")
        return
    end
    if not state.playedTotal then requestPlayed() end   -- time played arrives a moment later and refreshes the card
    showSnapshot(snap, true)
end

local function savedList()
    local names = {}
    for _, s in pairs((BarCheckDB and BarCheckDB.characters) or {}) do names[#names + 1] = s.display or "?" end
    table.sort(names)
    return names
end

local function findSaved(q)
    q = q:lower()
    local best
    for _, s in pairs((BarCheckDB and BarCheckDB.characters) or {}) do
        local n = (s.display or ""):lower()
        if n == q then return s end
        if n:find(q, 1, true) and not best then best = s end
    end
    return best
end

-- ---------- Bar Check! shout, character list and options ----------
local function chatChannel()
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    if IsInGuild and IsInGuild() then return "GUILD" end
    return "SAY"
end

-- the text summary of a snapshot, as a list of parts, using the stats chosen in the settings
local function summaryParts(snap)
    local who = displayName(snap)
    local id = snap.id or {}
    local parts = { "BAR CHECK! " .. tostring(who) .. ", level " .. tostring(snap.level) .. " " .. tostring(id.race or "") .. " " .. tostring(id.class or "") }
    local xp, xpMax = tonumber(snap.xp), tonumber(snap.xpMax)
    if xp and xpMax and xpMax > 0 then
        local f = math.max(0, math.min(0.9999, xp / xpMax))
        local bit = math.floor(f * 20) .. " bars in (" .. math.floor(f * 100 + 0.5) .. "% to level " .. (snap.level + 1) .. ")"
        if tonumber(snap.rested) and snap.rested > 0 then bit = bit .. ", rested" end
        parts[#parts + 1] = bit
    end
    for _, kind in ipairs(selectedStats()) do
        local v = statValue(kind, snap)
        if v ~= NA then parts[#parts + 1] = (STAT_LABEL[kind]:sub(1, 1) .. STAT_LABEL[kind]:sub(2):lower()) .. " " .. stripColors(v) end
    end
    return parts
end

-- one line of text for group chat
function BarCheck_Shout(channel)
    local ok, snap = pcall(buildSnapshot)
    if not ok or not snap or not snap.level then
        print("Bar Check: could not read your character yet. Try again in a moment.")
        return
    end
    local parts = summaryParts(snap)
    local lines, cur = {}, ""
    for _, part in ipairs(parts) do
        local trial = cur == "" and part or (cur .. " - " .. part)
        if #trial > 240 and cur ~= "" then lines[#lines + 1] = cur; cur = part else cur = trial end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    local ch = channel and channel:upper() or chatChannel()
    -- /say and /yell from an addon are blocked by the game outside instances, so when you are
    -- on your own the text goes into your chat box and you press Enter yourself
    if ch == "SAY" or type(SendChatMessage) ~= "function" then
        local first = lines[1] or ""
        if ChatFrame_OpenChat then
            ChatFrame_OpenChat("/s " .. (first:gsub("|", "/")))
            print("Bar Check: your line is in the chat box. Press Enter to say it, or Esc to cancel.")
        else
            print(first)
        end
        return
    end
    for _, msg in ipairs(lines) do
        local sent, err = pcall(SendChatMessage, (msg:gsub("|", "/")):sub(1, 250), ch)
        if not sent then
            print("|cffff6060Bar Check: could not send to " .. ch .. " (" .. tostring(err) .. ")|r")
            return
        end
    end
    print("Bar Check: sent to " .. ch:lower():gsub("_", " ") .. ".")
end

-- plain text of the card on screen, pre-selected in a box so it can be copied with Ctrl+C
function BarCheck_CopyText()
    if not lastSnap then
        print("Bar Check: open a card first.")
        return
    end
    local ok, parts = pcall(summaryParts, lastSnap)
    if not ok or not parts then
        print("|cffff6060Bar Check: could not build the text (" .. tostring(parts) .. ")|r")
        return
    end
    BarCheck_ShowText(table.concat(parts, "\n"), "Card text: press Ctrl+C to copy, then paste anywhere")
end

local charList
function BarCheck_ShowChars()
    if not card or not ui.charBtn then return end
    if charList and charList:IsShown() then charList:Hide(); return end
    local entries = { { label = "Current character", live = true } }
    local saved = {}
    for _, sv in pairs((BarCheckDB and BarCheckDB.characters) or {}) do saved[#saved + 1] = sv end
    table.sort(saved, function(a, b) return (a.display or "") < (b.display or "") end)
    for i = 1, math.min(#saved, 14) do
        entries[#entries + 1] = { label = tostring(saved[i].display or "?") .. "  (Lv " .. tostring(saved[i].level or "?") .. ")", snap = saved[i] }
    end
    if not charList then
        charList = CreateFrame("Frame", "BarCheckCharList", card, BackdropTemplateMixin and "BackdropTemplate" or nil)
        charList:SetFrameStrata("DIALOG")
        if charList.SetBackdrop then
            charList:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        end
        local shade = charList:CreateTexture(nil, "BACKGROUND", nil, 1)
        shade:SetPoint("TOPLEFT", 4, -4)
        shade:SetPoint("BOTTOMRIGHT", -4, 4)
        if shade.SetColorTexture then shade:SetColorTexture(0.03, 0.03, 0.06, 0.7) end
        charList.rows = {}
    end
    charList:SetSize(240, 14 + #entries * 22)
    charList:ClearAllPoints()
    charList:SetPoint("TOPLEFT", ui.charBtn, "BOTTOMLEFT", 0, -2)
    for i, e in ipairs(entries) do
        local row = charList.rows[i]
        if not row then
            row = CreateFrame("Button", nil, charList)
            row:SetSize(224, 20)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.text:SetPoint("LEFT", 6, 0)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            charList.rows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", charList, "TOPLEFT", 8, -7 - (i - 1) * 22)
        row.text:SetText(e.label)
        row:SetScript("OnClick", function()
            charList:Hide()
            if e.live then liveCard() else showSnapshot(e.snap, false) end
        end)
        row:Show()
    end
    for i = #entries + 1, #charList.rows do charList.rows[i]:Hide() end
    charList:Show()
end

local optionsFrame
function BarCheck_Options()
    if optionsFrame then
        if optionsFrame:IsShown() then optionsFrame:Hide() else optionsFrame:Show() end
        return
    end
    local o = opt()
    local f = CreateFrame("Frame", "BarCheckOptions", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    optionsFrame = f
    f:SetSize(340, 330 + #STAT_POOL * 28 + 4 * 28)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32, insets = { left = 8, right = 8, top = 8, bottom = 8 } })
    end
    -- the stock dialog background is see-through; darken it so the text is easy to read
    local shade = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    shade:SetPoint("TOPLEFT", 8, -8)
    shade:SetPoint("BOTTOMRIGHT", -8, 8)
    if shade.SetColorTexture then shade:SetColorTexture(0.03, 0.03, 0.06, 0.7) end
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if UISpecialFrames then table.insert(UISpecialFrames, "BarCheckOptions") end
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Bar Check options")
    local closeX = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeX:SetPoint("TOPRIGHT", -6, -6)

    local y = -48
    local function check(label, get, set)
        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetSize(26, 26)
        cb:SetPoint("TOPLEFT", 22, y)
        local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        t:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        t:SetText(label)
        cb:SetChecked(get())
        cb:SetScript("OnClick", function(self)
            set(self:GetChecked() and true or false, self)
            if BarCheck_Rerender then BarCheck_Rerender() end
        end)
        y = y - 28
        return cb
    end
    check("Play the build-up animation", function() return o.animate end, function(v) o.animate = v end)
    check("Faster animation", function() return o.fast end, function(v) o.fast = v end)
    check("Show the Bar Check! chat button on the card", function() return o.shout end, function(v) o.shout = v end)
    check("Show my guild name on the card", function() return o.showGuild end, function(v) o.showGuild = v end)
    check("Show the minimap button", function() return o.minimap end, function(v) o.minimap = v; BarCheck_ApplyMinimap() end)
    check("Tell me when a newer version exists", function() return o.versionCheck end, function(v) o.versionCheck = v end)

    local sl = CreateFrame("Slider", "BarCheckScaleSlider", f, "OptionsSliderTemplate")
    sl:SetPoint("TOPLEFT", 30, y - 22)
    sl:SetWidth(260)
    sl:SetMinMaxValues(50, 100)
    sl:SetValueStep(5)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
    sl:SetValue(o.scale or 100)
    local nm = sl.GetName and sl:GetName()
    if nm and _G[nm .. "Low"] then _G[nm .. "Low"]:SetText("50%"); _G[nm .. "High"]:SetText("100%") end
    if nm and _G[nm .. "Text"] then _G[nm .. "Text"]:SetText("Card size") end
    sl:SetScript("OnValueChanged", function(_, v)
        o.scale = math.floor((v or 100) / 5 + 0.5) * 5
        if BarCheck_Rerender then BarCheck_Rerender() end
    end)
    y = y - 64

    local hdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr:SetPoint("TOPLEFT", 24, y)
    hdr:SetText("Stats on the card (more rows are added as needed)")
    y = y - 22
    for _, e in ipairs(STAT_POOL) do
        check(e.label:sub(1, 1) .. e.label:sub(2):lower(), function() return o.stats[e.key] end, function(v, self)
            if not v then
                local n = 0
                for _, e2 in ipairs(STAT_POOL) do if o.stats[e2.key] then n = n + 1 end end
                if n <= 1 then self:SetChecked(true); return end
            end
            o.stats[e.key] = v
        end)
    end
    local doneBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    doneBtn:SetSize(90, 22)
    doneBtn:SetPoint("BOTTOM", 0, 16)
    doneBtn:SetText("Done")
    doneBtn:SetScript("OnClick", function() f:Hide() end)
    f:Show()
end

-- ---------- copy window (/bc export): raw data for troubleshooting ----------
local popup
local function showCopyWindow(text, titleText)
    if not popup then
        popup = CreateFrame("Frame", "BarCheckCopyFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        popup:SetSize(520, 160)
        popup:SetPoint("CENTER")
        popup:SetFrameStrata("FULLSCREEN_DIALOG")
        if popup.SetBackdrop then
            popup:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32, insets = { left = 8, right = 8, top = 8, bottom = 8 } })
        end
        popup:EnableMouse(true)
        local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -14)
        title:SetText("Bar Check data: press Ctrl+C to copy")
        popup.title = title
        local scroll = CreateFrame("ScrollFrame", "BarCheckCopyScroll", popup, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 18, -38)
        scroll:SetPoint("BOTTOMRIGHT", -36, 40)
        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(460)
        edit:SetAutoFocus(true)
        edit:SetScript("OnEscapePressed", function() popup:Hide() end)
        scroll:SetScrollChild(edit)
        popup.edit = edit
        local closeb = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
        closeb:SetSize(90, 22)
        closeb:SetPoint("BOTTOM", 0, 12)
        closeb:SetText("Close")
        closeb:SetScript("OnClick", function() popup:Hide() end)
    end
    popup.title:SetText(titleText or "Bar Check data: press Ctrl+C to copy")
    popup.edit:SetText(text)
    popup:Show()
    popup.edit:SetFocus()
    popup.edit:HighlightText()
end

BarCheck_ShowText = showCopyWindow

-- ---------- slash commands ----------
SLASH_BARCHECK1 = "/barcheck"
SLASH_BARCHECK2 = "/bc"
SlashCmdList["BARCHECK"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local low = msg:lower()
    if msg == "" then
        BarCheck_Toggle()
    elseif low == "button" or low == "reset" then
        if BarCheckDB then BarCheckDB.minimapRadius = nil; BarCheckDB.minimapAngle = nil end
        if opt() then opt().minimap = true end
        BarCheck_ApplyMinimap()
        if BarCheckMinimapButton and BarCheck_PlaceButton then BarCheck_PlaceButton(BarCheckMinimapButton) end
        print("Bar Check: minimap button reset. Drag it to move it around the minimap edge.")
    elseif low == "options" or low == "settings" or low == "config" then
        BarCheck_Options()
    elseif low == "shout" or low:find("^shout ") then
        BarCheck_Shout((low:match("^shout%s+(%a+)")))
    elseif low == "list" then
        local names = savedList()
        print("Bar Check, saved characters: " .. (#names > 0 and table.concat(names, ", ") or "none yet"))
    elseif low == "export" then
        save()
        local snap = BarCheckDB.characters[BarCheckDB.last]
        if snap then showCopyWindow(encode(snap)) end
    else
        local s = findSaved(msg)
        if s then
            showSnapshot(s, false)
        else
            local names = savedList()
            print("Bar Check: no saved character matches '" .. msg .. "'. Saved: " .. (#names > 0 and table.concat(names, ", ") or "none yet"))
        end
    end
end

-- ---------- minimap button ----------
local function placeButton(btn)
    local a = math.rad((BarCheckDB and BarCheckDB.minimapAngle) or 215)
    local w = Minimap:GetWidth()
    local r = (BarCheckDB and BarCheckDB.minimapRadius) or ((w and w > 50 and w / 2 or 70) + 5)
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

BarCheck_PlaceButton = placeButton

function BarCheck_ApplyMinimap()
    local b = BarCheckMinimapButton
    if not b then return end
    if opt().minimap then b:Show() else b:Hide() end
end

-- key binding target (Bindings.xml) and /bc with no argument
function BarCheck_Toggle()
    if card and card:IsShown() then card:Hide() else liveCard() end
end
BINDING_HEADER_BARCHECK = "Bar Check"
BINDING_NAME_BARCHECK_TOGGLE = "Show / hide my progress card"

local function makeMinimapButton()
    if not Minimap or BarCheckMinimapButton then return end
    local btn = CreateFrame("Button", "BarCheckMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            SlashCmdList["BARCHECK"]("list")
        elseif card and card:IsShown() then
            card:Hide()
        else
            liveCard()
        end
    end)
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local sc = Minimap:GetEffectiveScale()
            local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
            local dx, dy = cx / sc - mx, cy / sc - my
            BarCheckDB.minimapAngle = math.deg(atan2(dy, dx))
            local w = Minimap:GetWidth() or 140
            local d = math.sqrt(dx * dx + dy * dy)
            BarCheckDB.minimapRadius = math.max(w / 2 - 10, math.min(w / 2 + 60, d))
            placeButton(self)
        end)
    end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Bar Check")
        GameTooltip:AddLine("Click: show your progress card", 1, 1, 1)
        GameTooltip:AddLine("Right-click: list saved characters", 1, 1, 1)
        GameTooltip:AddLine("/bc <name>: show a saved character", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    placeButton(btn)
    BarCheck_ApplyMinimap()
end

-- ---------- newer-version notice ----------
-- Other Bar Check users in your guild or group send their version number; if one is newer than
-- yours you get a single reminder per session. Nothing else is sent or stored.
local MSG_PREFIX = "BarCheck"
local myVersion = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("BarCheck", "Version"))
    or (GetAddOnMetadata and GetAddOnMetadata("BarCheck", "Version")) or "0"
local notified, lastGroupPing = false, 0

local function versionParts(v)
    local t = {}
    for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end
local function isNewer(a, b)   -- is version a newer than b?
    local x, y = versionParts(a), versionParts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end
BarCheck_IsNewer = isNewer

local function sendVersion(channel)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) or not opt().versionCheck then return end
    pcall(C_ChatInfo.SendAddonMessage, MSG_PREFIX, "V:" .. myVersion, channel)
end
local function pingGroup()
    local now = type(GetTime) == "function" and GetTime() or 0
    if now - lastGroupPing < 60 then return end
    lastGroupPing = now
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then sendVersion("INSTANCE_CHAT")
    elseif IsInRaid and IsInRaid() then sendVersion("RAID")
    elseif IsInGroup and IsInGroup() then sendVersion("PARTY") end
end
local function onAddonMessage(prefix, text, _, sender)
    if prefix ~= MSG_PREFIX or notified or not opt().versionCheck then return end
    local v = tostring(text or ""):match("^V:([%d%.]+)$")
    if v and isNewer(v, myVersion) then
        notified = true
        print("Bar Check: version " .. v .. " is available (you have " .. myVersion .. "). Get it on CurseForge.")
    end
end

-- ---------- events ----------
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
frame:RegisterEvent("TIME_PLAYED_MSG")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")

frame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" then
        if arg1 == "BarCheck" then
            BarCheckDB = BarCheckDB or {}
            if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then pcall(C_ChatInfo.RegisterAddonMessagePrefix, MSG_PREFIX) end
            pcall(makeMinimapButton)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if C_Timer and C_Timer.After then
            C_Timer.After(4, function() requestPlayed(); C_Timer.After(2, save) end)
            C_Timer.After(10, function()
                if IsInGuild and IsInGuild() then sendVersion("GUILD") end
                pingGroup()
            end)
        end
    elseif event == "TIME_PLAYED_MSG" then
        state.playedTotal, state.playedLevel = arg1, arg2
        state.playedAt = type(GetTime) == "function" and GetTime() or nil
        if C_Timer and C_Timer.After then C_Timer.After(0, restoreChat) end
        BarCheck_Refresh()
    elseif event == "PLAYER_DEAD" then
        local c = counters(try(UnitGUID, "player")); c.deaths = c.deaths + 1
    elseif event == "QUEST_TURNED_IN" then
        local c = counters(try(UnitGUID, "player")); c.quests = c.quests + 1
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        local c = counters(try(UnitGUID, "player")); c.kills = c.kills + 1
    elseif event == "CHAT_MSG_ADDON" then
        onAddonMessage(arg1, arg2, arg3, arg4)
    elseif event == "GROUP_ROSTER_UPDATE" then
        pingGroup()
    elseif event == "PLAYER_LOGOUT" then
        save()
    end
end)
