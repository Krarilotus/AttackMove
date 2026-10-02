--[[
  Attack Move

  1. Shift waypoints at any time. With troops selected, a Shift-click on the map either starts
     a route (a move order flagged as a waypoint route, -1, or a patrol, 1) or adds a point to
     the group's route (command 0x47). Which one is decided by a counter of the client
     (TribesState +0x20): 1 starts, anything else adds. The counter is set to 1 only when
     troops are selected, and a normal move order sets it to 2. The group's own route flag
     (+0x22E VAN / +0x582 EXT) goes back to 0 when a route is finished, and a normal move
     order sets it to 0 too - and the group update only walks the points while the flag is
     set. So after any move, Shift-clicks stored points nobody walked.
     Now a Shift-click looks at the group first: a live route (flag set) or a route that was
     just ordered and has not started yet is extended; a normal move that is still under way
     becomes the route's first leg (option); anything else starts a fresh route.
     The stance behaviour on the way (ranged groups stop and shoot, melee units go for enemies
     in stance range) is the game's own: it is tied to the same route flag.
  2. Alt to stack. With troops selected, the click handler asks getUnitInHitBox(5) for a unit
     of the player under the cursor and, if there is one, the click selects it, and
     getUnitInHitBox(1) for an enemy, which turns the click into an attack order. While Alt is
     held (the game's own modifier state) both questions get "none", so the click is a move.

  Every address is found by pattern scan or read out of the instruction that uses it, so the
  module runs on Stronghold Crusader.exe and Stronghold_Crusader_Extreme.exe alike.
]]

local MODULE_NAME = "attack-move"

local DEFAULTS = {
  waypoints = { always = true, continue_move = true },
  stacking = { alt = true },
}

-- How long after a route was ordered it still counts as "ordered, not started yet", in game
-- ticks (40 a second at normal speed). Covers the command delay in multiplayer.
local PENDING_TICKS = 200

---------------------------------------------------------------------------------------
-- What the game's code looks like where this module touches it
---------------------------------------------------------------------------------------

-- The click handler's Shift branch (troops selected, map clicked):
--   cmp [shift], edi / je normalMove / mov ecx, [patrolButton] / cmp ecx, edi /
--   mov eax, [rallyCount] / je ... / cmp eax, 0xA / mov [esp+0x2C], ebp / jge ... /
--   cmp eax, ebp / jne addPoint / ... giveMoveCommand(group, x, y, patrol, 1)
local AOB_SHIFT = "39 3D ? ? ? ? 0F 84 ? ? ? ? 8B 0D ? ? ? ? 3B CF A1 ? ? ? ? 74 4B 83 F8 0A "
  .. "89 6C 24 2C 0F 8D"
local SHIFT_FLAG = 0x02                  -- operand: ModifierKeyState +8 (shift), +0xC is alt
local SHIFT_TO_ALT = 4
local SHIFT_NORMAL_MOVE = 0x06           -- je rel32 to the normal move order
local SHIFT_HOOK = 0x0C                  -- mov ecx, [patrolButton] (6 bytes)
local SHIFT_HOOK_SIZE = 6
local SHIFT_PATROL = { 0x0C, { 0x8B, 0x0D } }
local SHIFT_RALLY_COUNT = { 0x14, { 0xA1 } }
local SHIFT_MOUSE_Y = { 0x30, { 0xA1 } }
local SHIFT_MOUSE_X = { 0x3D, { 0x8B, 0x0D } }
local SHIFT_UNITS_STATE = { 0x46, { 0xB9 } }
local SHIFT_GIVE_MOVE = 0x4B             -- call giveMoveCommand
local NORMAL_MOVE_HOOK_SIZE = 6          -- call [GetTickCount]
local TRIBES_PATROL = 0x1C               -- TribesState +0x1C patrol button, +0x20 rally count
local TRIBES_RALLY_COUNT = 0x20

-- The group update, where it walks a route:
--   cmp word [esi+routeFlag], bx / je / push ebp / mov ecx, edi / call allUnitsReached /
--   test / je / movsx eax, [esi+routeStep] / movsx ecx, [esi+routeCount] / add eax, 1 / cmp
-- esi is the group: TribesState + group * size.
local AOB_ROUTE = "66 39 9E ? ? 00 00 0F 84 ? ? ? ? 55 8B CF E8 ? ? ? ? 85 C0 0F 84 ? ? ? ? "
  .. "0F BF 86 ? ? 00 00 0F BF 8E ? ? 00 00 83 C0 01 3B C1"
local ROUTE_FLAG = 0x03
local ROUTE_ALL_ARRIVED = 0x10           -- call allUnitsReachedTheirDestination(group)
local ROUTE_STEP = 0x20
local ROUTE_GROUP_SIZE = { 0x5F, { 0x69, 0xD2 } }    -- imul edx, edx, size / 4
local ROUTE_POINTS = { 0x68, { 0x0F, 0xBF, 0x94, 0x8F } }
local GROUP_UID = 0x34

-- The game tick counter (the stance search's frequency test in updateUnits).
local AOB_TICKS = "8B 87 50 0A 00 00 8B 8F 98 09 00 00 8B 15"
local TICKS_OPERAND = 0x0E

-- The two places where a click with troops selected asks for a unit of the player under the
-- cursor: push 5 / mov ecx, UnitsState / call getUnitInHitBox.
local AOB_HOVER_UNIT = "6A 05 B9 ? ? ? ? E8 ? ? ? ? 33 DB 3B C3 0F 84 ? ? ? ? 8B F0 69 F6 90 04 00 00 "
  .. "66 39 9E"
local AOB_CLICK_UNIT = "6A 05 B9 ? ? ? ? E8 ? ? ? ? 85 C0 74 ? B9 ? ? ? ? E8 ? ? ? ? B9 ? ? ? ? E8 ? ? "
  .. "? ? B9"
local UNIT_CALL = 0x07
-- The two places where the cursor looks for an enemy unit to attack: getUnitInHitBox(1).
local ENEMY_SITES = {
  { pattern = "6A 04 6A 04 B9 ? ? ? ? E8 ? ? ? ? 6A 01 B9 ? ? ? ? E8 ? ? ? ? 8B D8 85 DB 0F 84", call = 0x15 },
  { pattern = "6A 01 B9 ? ? ? ? E8 ? ? ? ? 8B F8 85 FF 74 ? 57 E8", call = 0x07 },
}
local CLICK_SELECTION_COUNT = { 0x42, { 0x39, 0x3D } }   -- cmp [UnitsState.totalUnitsInSelection], edi

---------------------------------------------------------------------------------------
-- Injected code
---------------------------------------------------------------------------------------

-- A Shift-click with troops selected, before the game reads its rally counter.
-- LAST: +0 group, +4 group uid, +8 tick, +0xC x, +0x10 y, +0x14 kind (1 move, 2 route).
local SHIFT_CLICK = [[
pushad
mov ecx,[TRIBES]
imul edx,ecx,GROUP_SIZE
add edx,TRIBES
cmp dword [RALLY_COUNT],1
je started
cmp word [edx+ROUTE_FLAG],0
jne finish
cmp ecx,[LAST]
jne fresh
mov eax,[edx+GROUP_UID]
cmp eax,[LAST+4]
jne fresh
mov eax,[TICKS]
sub eax,[LAST+8]
cmp dword [LAST+0x14],2
jne after_move
cmp eax,PENDING_TICKS
jae fresh
cmp word [edx+ROUTE_STEP],0
jne finish
mov eax,[LAST+0xC]
cmp word [edx+FIRST_POINT],ax
jne finish
mov eax,[LAST+0x10]
cmp word [edx+FIRST_POINT+2],ax
jne finish
jmp fresh
after_move:
cmp dword [LAST+0x14],1
jne fresh
cmp byte [CONTINUE_ON],0
je fresh
cmp eax,PENDING_TICKS
jb continue_move
push ecx
mov ecx,TRIBES
call ALL_ARRIVED
test eax,eax
jne fresh
continue_move:
push 1
mov eax,[PATROL]
test eax,eax
jne have_flag
or eax,-1
have_flag:
push eax
push dword [LAST+0x10]
push dword [LAST+0xC]
push dword [TRIBES]
mov ecx,UNITS_STATE
call GIVE_MOVE
mov dword [RALLY_COUNT],2
mov eax,[TICKS]
mov [LAST+8],eax
mov dword [LAST+0x14],2
inc dword [DIAG+8]
jmp finish
fresh:
mov dword [RALLY_COUNT],1
inc dword [DIAG+4]
started:
mov ecx,[TRIBES]
mov [LAST],ecx
imul edx,ecx,GROUP_SIZE
mov eax,[edx+TRIBES+GROUP_UID]
mov [LAST+4],eax
mov eax,[TICKS]
mov [LAST+8],eax
mov eax,[MOUSE_X]
mov [LAST+0xC],eax
mov eax,[MOUSE_Y]
mov [LAST+0x10],eax
mov dword [LAST+0x14],2
finish:
inc dword [DIAG]
popad
ORIGINAL
jmp RESUME
]]

-- A normal (no Shift) move order: remember it.
local NORMAL_MOVE = [[
push eax
push edx
mov eax,[TRIBES]
mov [LAST],eax
imul eax,eax,GROUP_SIZE
mov edx,[eax+TRIBES+GROUP_UID]
mov [LAST+4],edx
mov eax,[TICKS]
mov [LAST+8],eax
mov eax,[MOUSE_X]
mov [LAST+0xC],eax
mov eax,[MOUSE_Y]
mov [LAST+0x10],eax
mov dword [LAST+0x14],1
pop edx
pop eax
ORIGINAL
jmp RESUME
]]

-- Stands in for getUnitInHitBox (thiscall on UnitsState, ret 4) where the click handler asks
-- for your own troops (5) or an enemy (1) under the cursor.
local ALT_UNIT = [[
cmp dword [ALT],0
je ask
cmp dword [ecx+SELECTION_COUNT],0
jle ask
xor eax,eax
ret 4
ask:
jmp GET_UNIT
]]

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local function scan(pattern, purpose)
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok or address == nil then
    error(MODULE_NAME .. ": could not find " .. purpose)
  end
  return address
end

local function expectBytes(address, bytes, purpose)
  for index, byte in ipairs(bytes) do
    if (core.readByte(address + index - 1) & 0xFF) ~= byte then
      error(string.format("%s: %s at 0x%X is not the code this module knows", MODULE_NAME, purpose,
        address))
    end
  end
end

local function readOperand(base, site, purpose)
  expectBytes(base + site[1], site[2], purpose)
  return core.readInteger(base + site[1] + #site[2])
end

local function readCallTarget(base, offset, purpose)
  expectBytes(base + offset, { 0xE8 }, purpose)
  return base + offset + 5 + core.readInteger(base + offset + 1)
end

local function originalBytes(address, size)
  local bytes = {}
  for index = 0, size - 1 do
    bytes[#bytes + 1] = string.format("0x%02X", core.readByte(address + index) & 0xFF)
  end
  return "db " .. table.concat(bytes, ",")
end

-- FASM gets a fixed 64 KB for source, symbols and output: only pass what a script uses.
local function assemble(script, values, original)
  if original ~= nil then
    script = script:gsub("%f[%w_]ORIGINAL%f[^%w_]", original)
  end
  local used = {}
  for name, value in pairs(values) do
    if script:find("%f[%w_]" .. name .. "%f[^%w_]") then
      used[name] = value
    end
  end
  return core.allocateAssembly(script, used)
end

local function jumpTo(address, target, size)
  local code = { 0xE9, core.itob(core.getRelativeAddress(address, target, -5)) }
  for _ = 6, size do
    code[#code + 1] = 0x90
  end
  core.writeCode(address, code)
end

local function setting(config, group, name)
  local section = config[group]
  if type(section) == "table" and section[name] ~= nil then
    return section[name]
  end
  return DEFAULTS[group][name]
end

---------------------------------------------------------------------------------------
-- The changes
---------------------------------------------------------------------------------------

local function patchWaypoints(shift, continueMove)
  local route = scan(AOB_ROUTE, "where a group walks its route")
  local patrol = readOperand(shift, SHIFT_PATROL, "the patrol button")
  local tribes = patrol - TRIBES_PATROL
  local rallyCount = readOperand(shift, SHIFT_RALLY_COUNT, "the waypoint counter")
  if rallyCount ~= tribes + TRIBES_RALLY_COUNT then
    error(MODULE_NAME .. ": the groups are not laid out the way this module knows")
  end
  local groupSize = readOperand(route, ROUTE_GROUP_SIZE, "the group size") * 4
  local values = {
    TRIBES = tribes,
    PATROL = patrol,
    RALLY_COUNT = rallyCount,
    GROUP_SIZE = groupSize,
    GROUP_UID = GROUP_UID,
    ROUTE_FLAG = core.readInteger(route + ROUTE_FLAG),
    ROUTE_STEP = core.readInteger(route + ROUTE_STEP),
    FIRST_POINT = readOperand(route, ROUTE_POINTS, "the route points") + 4,
    ALL_ARRIVED = readCallTarget(route, ROUTE_ALL_ARRIVED, "the arrival test"),
    UNITS_STATE = readOperand(shift, SHIFT_UNITS_STATE, "the units"),
    GIVE_MOVE = readCallTarget(shift, SHIFT_GIVE_MOVE, "the move order"),
    MOUSE_X = readOperand(shift, SHIFT_MOUSE_X, "the clicked tile"),
    MOUSE_Y = readOperand(shift, SHIFT_MOUSE_Y, "the clicked tile"),
    TICKS = core.readInteger(scan(AOB_TICKS, "the tick counter") + TICKS_OPERAND),
    PENDING_TICKS = PENDING_TICKS,
    LAST = core.allocate(0x18, true),
    CONTINUE_ON = core.allocate(4, true),
    DIAG = core.allocate(16, true),
  }
  core.writeByte(values.CONTINUE_ON, continueMove and 1 or 0)

  -- The normal move order: the target of the Shift test's je.
  expectBytes(shift + SHIFT_NORMAL_MOVE, { 0x0F, 0x84 }, "the Shift test")
  local normalMove = shift + SHIFT_NORMAL_MOVE + 6 + core.readInteger(shift + SHIFT_NORMAL_MOVE + 2)
  expectBytes(normalMove, { 0xFF, 0x15 }, "the normal move order")

  local site = shift + SHIFT_HOOK
  values.RESUME = site + SHIFT_HOOK_SIZE
  local stub = assemble(SHIFT_CLICK, values, originalBytes(site, SHIFT_HOOK_SIZE))
  values.RESUME = normalMove + NORMAL_MOVE_HOOK_SIZE
  local record = assemble(NORMAL_MOVE, values, originalBytes(normalMove, NORMAL_MOVE_HOOK_SIZE))
  jumpTo(site, stub, SHIFT_HOOK_SIZE)
  jumpTo(normalMove, record, NORMAL_MOVE_HOOK_SIZE)
  log(INFO, string.format("%s: Shift waypoints work at any time (groups 0x%X, size 0x%X, route flag "
    .. "+0x%X)", MODULE_NAME, tribes, groupSize, values.ROUTE_FLAG))
end

local function patchAltStacking(shift)
  local hover = scan(AOB_HOVER_UNIT, "where the cursor looks for your troops")
  local click = scan(AOB_CLICK_UNIT, "where a click selects your troops")
  local getUnit = readCallTarget(hover, UNIT_CALL, "the unit search")
  if readCallTarget(click, UNIT_CALL, "the unit search") ~= getUnit then
    error(MODULE_NAME .. ": the two unit searches are not the same function")
  end
  local unitsState = core.readInteger(click + 3)
  local stub = assemble(ALT_UNIT, {
    ALT = core.readInteger(shift + SHIFT_FLAG) + SHIFT_TO_ALT,
    SELECTION_COUNT = readOperand(click, CLICK_SELECTION_COUNT, "the selection count") - unitsState,
    GET_UNIT = getUnit,
  })
  local sites = { hover + UNIT_CALL, click + UNIT_CALL }
  for _, enemy in ipairs(ENEMY_SITES) do
    local site = scan(enemy.pattern, "where the cursor looks for enemies") + enemy.call
    if readCallTarget(site, 0, "the enemy search") ~= getUnit then
      error(MODULE_NAME .. ": the enemy search is not the unit search")
    end
    sites[#sites + 1] = site
  end
  for _, site in ipairs(sites) do
    core.writeCode(site, { 0xE8, core.itob(core.getRelativeAddress(site, stub, -5)) })
  end
  log(INFO, MODULE_NAME .. ": Alt + click moves onto your own troops and into enemies")
end

local function enable(self, config)
  config = config or {}
  local shift = scan(AOB_SHIFT, "the Shift-click order")
  if setting(config, "waypoints", "always") then
    patchWaypoints(shift, setting(config, "waypoints", "continue_move"))
  end
  if setting(config, "stacking", "alt") then
    patchAltStacking(shift)
  end
end

return {
  enable = enable,
  disable = function(self, config) end,
}
