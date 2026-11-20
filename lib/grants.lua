-- Admins only, with editing given to someone: an owner or admin lets a guest or a member edit in one room as an admin would, without making
-- them a studio admin (James, 2026-11-20: "Admins only makes sense too as well as a way to give guests or other users editing access as an
-- admin+"). It counts only in that room, only in Admins only, and only for editing the project (sync.authority's admins branch): a guest's
-- other limits (lib/trust.lua, lib/groups.lua) stay as they are.
--   rooms/<room>/grants/<admin>.json   { by = admin, users = { [name] = { on = true|false, at = ISO time } } }
-- One file per admin who gave or took back (one writer each, as released/). It counts only when its name is its `by`, that person may
-- manage the studio now, and Syncthing says their own computer wrote it (trust.claim_ok, as for a given claim). The newest word on a person
-- wins across the files; the same second, taking back wins.
local band = require("band")
local grants = {}
grants.NAME_MAX = 64

local function dir_of(cfg, song, room) return require("sync").room_dir(cfg, song, room) .. "/grants" end
local function file_of(user) return (user:gsub("[^%w%-_ ]", "")) .. ".json" end
local function iso() return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()) end

-- Who may edit here by a grant: { [name] = { by, at } }, from every file that counts.
function grants.list(cfg, song, room)
  local dir, best = dir_of(cfg, song, room), {}
  local names = band.listing and band.listing(dir, ".json", true) or band.files(dir, ".json")
  for _, f in ipairs(names) do
    local g = band.read_json(dir .. "/" .. f)
    if type(g) == "table" and type(g.by) == "string" and file_of(g.by) == f and type(g.users) == "table" and require("groups").may_manage(cfg.root, g.by)
        and require("trust").claim_ok(cfg.root, song .. "/rooms/" .. room .. "/grants/" .. f, g) == true then
      for user, e in pairs(g.users) do
        if type(user) == "string" and type(e) == "table" and type(e.at) == "string" then
          local o = best[user]
          if not o or e.at > o.at or (e.at == o.at and e.on ~= true) then best[user] = { on = e.on == true, at = e.at, by = g.by } end
        end
      end
    end
  end
  local out = {}
  for user, e in pairs(best) do if e.on then out[user] = { by = e.by, at = e.at } end end
  return out
end
-- Names, sorted. Pure.
function grants.names(set)
  local out = {}
  for u in pairs(set or {}) do out[#out + 1] = u end
  table.sort(out)
  return out
end

-- Give (on) or take back editing in this room from `user`. Only the studio's owner or an admin. -> words for the log, or nil and why.
function grants.set(cfg, song, room, user, on)
  local groups = require("groups")
  if not groups.may_manage(cfg.root, cfg.user) then return nil, "only the studio's owner or an admin lets people edit in Admins only" end
  if type(user) ~= "string" or user == "" or #user > grants.NAME_MAX or user:find("%c") then return nil, "not a name" end
  if on and groups.may_manage(cfg.root, user) then return nil, user .. " is already an owner or admin: they edit here anyway" end
  local dir = dir_of(cfg, song, room)
  local path = dir .. "/" .. file_of(cfg.user)
  local g = band.read_json(path)
  if g == nil and reaper.file_exists(path) then return nil, "the grants file is busy (syncing?): try again in a moment" end
  g = type(g) == "table" and type(g.users) == "table" and g or { users = {} }
  g.by, g.users[user] = cfg.user, { on = on == true, at = iso() }
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(path, g)
  local said = on and (cfg.user .. " let " .. user .. " edit in '" .. room .. "' as an admin would (Admins only, this room only)")
    or (cfg.user .. " took back " .. user .. "'s editing in '" .. room .. "'")
  band.log(said)
  return said
end

-- The web page's Grant / Revoke (topic "grants": { user, on }). -> words for the log only when it didn't go through: grants.set has logged
-- the grant itself (it was in the log twice: REAPER check, 0.59.49.73).
function grants.web_action(cfg, b, a)
  if type(a) ~= "table" then return nil end
  local said, why = grants.set(cfg, b.song, b.room, a.user, a.on == true)
  if not said then return "the web page's grant: " .. tostring(why) end
end

-- A Health line while the room is Admins only and someone has a grant, or nil.
function grants.health_words(cfg, b)
  local sync = require("sync")
  if sync.mode(cfg, b.song, b.room) ~= "admins" then return nil end
  local list = grants.names(grants.list(cfg, b.song, b.room))
  if #list == 0 then return nil end
  return "Admins only in '" .. b.room .. "': " .. table.concat(list, ", ") .. (#list == 1 and " edits" or " edit") .. " here too (given by an admin, this room only)"
end

-- The panel's part of Who controls, in Admins only: who has a grant (owner and admins: x takes it back) and Let edit for whoever's here.
-- people: the names to offer (who's here). Called inside the panel's own pcall.
function grants.panel(ctx, ImGui, cfg, b, people, may_set)
  local set = grants.list(cfg, b.song, b.room)
  local list = grants.names(set)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, #list > 0 and ("Can edit here too: " .. table.concat(list, ", ")) or "Nobody else is let edit here")
  ImGui.SetItemTooltip(ctx, "People an owner or admin let edit in this room as an admin would. Only here, and only the project: a guest's other limits stay.")
  if not may_set then return end
  for _, u in ipairs(list) do
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Revoke " .. u .. "##grant") then
      local said, why = grants.set(cfg, b.song, b.room, u, false)
      if not said then band.msg(why) end
    end
  end
  local groups, offer = require("groups"), {}
  for _, u in ipairs(people or {}) do if u ~= cfg.user and not set[u] and not groups.may_manage(cfg.root, u) then offer[#offer + 1] = u end end
  if #offer == 0 then return end
  ImGui.SetNextItemWidth(ctx, 180)
  if ImGui.BeginCombo(ctx, "##grantpick", "Let someone edit here...") then
    for _, u in ipairs(offer) do
      if ImGui.Selectable(ctx, u, false) then
        local said, why = grants.set(cfg, b.song, b.room, u, true)
        if not said then band.msg(why) end
      end
    end
    ImGui.EndCombo(ctx)
  end
end

return grants
