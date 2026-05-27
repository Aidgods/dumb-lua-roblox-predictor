-- Predicted Position Visualizer

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

if _G.PredictedOrbVisualizer then print("[OrbVis] Already running.") return end
_G.PredictedOrbVisualizer = true

local localPlayer = Players.LocalPlayer
if not localPlayer then
    repeat task.wait(0.1) until Players.LocalPlayer
    localPlayer = Players.LocalPlayer
end
local localName = localPlayer.Name

local WORLD_ORB_RADIUS  = 0.05
local MAX_SCREEN_RADIUS = 40
local MIN_SCREEN_RADIUS = 5
local HISTORY_SIZE      = 120
local TARGET_LATENCY_S  = 0.15
local UPDATE_HZ         = 120
local UPDATE_INTERVAL   = 1 / UPDATE_HZ

local TWO_PI = math.pi * 2
local PI     = math.pi

local function worldToScreen(worldPos)
    local ok, sp, onScreen = pcall(WorldToScreen, worldPos)
    if not ok or not sp then return nil, false end
    return sp, onScreen
end

local playerDrawings = {}
local playerHistory  = {}
local DRAW_KEYS = { "lineOutline", "line", "border", "fill", "ring", "pingText", "nameText" }

local function createDrawing(name)
    local lineOutline = Drawing.new("Line")
    lineOutline.Thickness    = 5
    lineOutline.Color        = Color3.new(0, 0, 0)
    lineOutline.Transparency = 0.7
    lineOutline.Visible      = false
    lineOutline.ZIndex       = 8

    local line = Drawing.new("Line")
    line.Thickness    = 3
    line.Color        = Color3.new(1, 1, 1)
    line.Transparency = 0.7
    line.Visible      = false
    line.ZIndex       = 9

    local border = Drawing.new("Circle")
    border.Filled       = true
    border.Transparency = 0.0
    border.Color        = Color3.new(0, 0, 0)
    border.Visible      = false
    border.ZIndex       = 10

    local fill = Drawing.new("Circle")
    fill.Filled       = true
    fill.Transparency = 0.15
    fill.Visible      = false
    fill.ZIndex       = 11

    local ring = Drawing.new("Circle")
    ring.Filled       = false
    ring.Thickness    = 1
    ring.Color        = Color3.new(1, 1, 1)
    ring.Transparency = 0.3
    ring.Visible      = false
    ring.ZIndex       = 12

    local pingText = Drawing.new("Text")
    pingText.Size    = 0.001
    pingText.Color   = Color3.new(1, 1, 1)
    pingText.Outline = true
    pingText.Center  = true
    pingText.Visible = false
    pingText.ZIndex  = 13

    local nameText = Drawing.new("Text")
    nameText.Size    = 0.001
    nameText.Color   = Color3.new(1, 1, 1)
    nameText.Outline = true
    nameText.Center  = true
    nameText.Text    = name
    nameText.Visible = false
    nameText.ZIndex  = 13

    return {
        lineOutline = lineOutline, line = line,
        border = border, fill = fill, ring = ring,
        pingText = pingText, nameText = nameText,
        lastTErr = -1, lastPingUpdate = 0,
        lastSX = 0, lastSY = 0, lastRadius = 0,
    }
end

local function setAllVisible(data, vis)
    for i = 1, #DRAW_KEYS do data[DRAW_KEYS[i]].Visible = vis end
end

local function getOrCreate(name)
    if not playerDrawings[name] then playerDrawings[name] = createDrawing(name) end
    return playerDrawings[name]
end

local function removeDrawing(name)
    local data = playerDrawings[name]
    if data then
        for i = 1, #DRAW_KEYS do
            pcall(data[DRAW_KEYS[i]].Remove, data[DRAW_KEYS[i]])
        end
    end
    playerDrawings[name] = nil
    playerHistory[name]  = nil
end

local activePlayers = {}

local function addPlayer(p)
    if p.Name ~= localName then activePlayers[p.Name] = p end
end
local function dropPlayer(p)
    activePlayers[p.Name] = nil
    removeDrawing(p.Name)
end

for _, p in ipairs(Players:GetPlayers()) do addPlayer(p) end
Players.PlayerAdded:Connect(addPlayer)
Players.PlayerRemoving:Connect(dropPlayer)

local function newRing()
    local buf = {}
    for i = 1, HISTORY_SIZE do
        buf[i] = { t=0, px=0,py=0,pz=0, vx=0,vy=0,vz=0,
                   mx=0,my=0,mz=0, yaw=0, yawRate=0 }
    end
    return { buf=buf, head=0, size=0 }
end

local function ringPush(r, hrp)
    local prevHead = r.head
    local h        = (prevHead % HISTORY_SIZE) + 1
    local s        = r.buf[h]

    local pos  = hrp.Position
    local vel  = hrp.AssemblyLinearVelocity
    local lv   = hrp.CFrame.LookVector
    local mass = hrp.AssemblyMass
    if not mass or mass <= 0 then mass = 1 end

    local now     = tick()
    local newYaw  = math.atan2(-lv.X, -lv.Z)
    local yawRate = 0

    if r.size > 0 then
        local prev = r.buf[(prevHead - 1) % HISTORY_SIZE + 1]
        local dtt  = now - prev.t
        if dtt > 0 then
            local diff = (newYaw - prev.yaw) % TWO_PI
            if diff > PI then diff = diff - TWO_PI end
            yawRate = diff / dtt
        end
    end

    s.t   = now
    s.px  = pos.X;      s.py  = pos.Y;      s.pz  = pos.Z
    s.vx  = vel.X;      s.vy  = vel.Y;      s.vz  = vel.Z
    s.mx  = vel.X*mass; s.my  = vel.Y*mass; s.mz  = vel.Z*mass
    s.yaw = newYaw;     s.yawRate = yawRate

    r.head = h
    if r.size < HISTORY_SIZE then r.size = r.size + 1 end
    return now, pos
end

local function findSnapshot(r, now)
    local target   = now - TARGET_LATENCY_S
    local buf      = r.buf
    local best, bestDiff = nil, math.huge
    for i = 1, r.size do
        local f    = buf[i]
        local diff = f.t - target
        if diff < 0 then diff = -diff end
        if diff < bestDiff then
            bestDiff = diff
            best     = f
            if bestDiff < 0.001 then break end
        end
    end
    return best
end

-- prediction made by adgods :3
local function predictXYZ(vx, vy, vz, mx, my, mz, yawRate, dt)
    local mom_x_dt_sq       = mx * dt * dt
    local mom_y_dt_sq       = my * dt * dt
    local mom_z_dt_cb       = mz * dt * dt * dt
    local yaw_rate_dt       = yawRate * dt
    local yaw_rate_sq_dt_sq = yawRate * yawRate * dt * dt
    local mom_y_vel_y       = my * vy
    local corr_x = mom_z_dt_cb * (yawRate / (yaw_rate_sq_dt_sq * yaw_rate_sq_dt_sq + 0.35263535))
    local corr_y = math.max(math.abs(mom_y_dt_sq) - mom_y_vel_y, 0) / -0.26091227
    local corr_z = yaw_rate_dt * (mom_x_dt_sq / (-0.28429636 - yaw_rate_sq_dt_sq))
    return (vx*dt) + corr_x, (vy*dt) + corr_y, (vz*dt) + corr_z
end

local _cachedFov, _cachedVpH, _cachedScale = 0, 0, 1

local function computeScreenRadius(dist, cam)
    local fov = cam.FieldOfView or 70
    local vpH = cam.ViewportSize.Y
    if fov ~= _cachedFov or vpH ~= _cachedVpH then
        _cachedFov = fov; _cachedVpH = vpH
        _cachedScale = vpH / (2 * math.tan(math.rad(fov * 0.5)))
    end
    if dist < 0.5 then dist = 0.5 end
    return math.clamp((WORLD_ORB_RADIUS / dist) * _cachedScale, MIN_SCREEN_RADIUS, MAX_SCREEN_RADIUS)
end

local lastDebugPrint = 0

local function updatePlayer(name, player)
    local char = player.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    if not playerHistory[name] then playerHistory[name] = newRing() end
    local r = playerHistory[name]

    local ok, now, curPos = pcall(ringPush, r, hrp)
    if not ok then return end
    if r.size < 10 then return end

    local snapshot = findSnapshot(r, now)
    if not snapshot or snapshot.t == 0 then return end

    local dt    = now - snapshot.t
    local dt_ms = dt * 1000
    if dt_ms < 5 then return end

    local dx, dy, dz = predictXYZ(
        snapshot.vx, snapshot.vy, snapshot.vz,
        snapshot.mx, snapshot.my, snapshot.mz,
        snapshot.yawRate, dt
    )

    local predX = snapshot.px + dx
    local predY = snapshot.py + dy
    local predZ = snapshot.pz + dz

    local cam = Workspace.CurrentCamera
    if not cam then return end

    local wpX, wpY, wpZ = predX, predY + 2, predZ
    local camPos = cam.Position
    local dX, dY, dZ = wpX - camPos.X, wpY - camPos.Y, wpZ - camPos.Z
    local dist = math.sqrt(dX*dX + dY*dY + dZ*dZ)
    if dist > 1500 then
        local d = playerDrawings[name]; if d then setAllVisible(d, false) end; return
    end

    local sp, inFront = worldToScreen(Vector3.new(wpX, wpY, wpZ))
    if not inFront then
        local d = playerDrawings[name]; if d then setAllVisible(d, false) end; return
    end

    local vpSize   = cam.ViewportSize
    local vpW, vpH = vpSize.X, vpSize.Y
    if sp.X < -vpW or sp.X > 2*vpW or sp.Y < -vpH or sp.Y > 2*vpH then
        local d = playerDrawings[name]; if d then setAllVisible(d, false) end; return
    end

    local radius = computeScreenRadius(dist, cam)
    local sx = math.clamp(sp.X, radius + 2, vpW - radius - 2)
    local sy = math.clamp(sp.Y, radius + 2, vpH - radius - 2)

    local eX = curPos.X - predX
    local eY = curPos.Y - predY
    local eZ = curPos.Z - predZ
    local tErr  = math.clamp((math.sqrt(eX*eX + eY*eY + eZ*eZ) - 0.5) / 4, 0, 1)
    local tErrQ = math.floor(tErr * 20 + 0.5) / 20

    local data = getOrCreate(name)

    local posChanged = (sx ~= data.lastSX or sy ~= data.lastSY)
    local radChanged = (radius ~= data.lastRadius)

    if posChanged or radChanged then
        local pos2 = Vector2.new(sx, sy)
        data.lastSX = sx; data.lastSY = sy; data.lastRadius = radius
        data.border.Position   = pos2; data.border.Radius = radius + 2.5
        data.fill.Position     = pos2; data.fill.Radius   = radius
        data.ring.Position     = pos2; data.ring.Radius   = radius
        data.pingText.Position = Vector2.new(sx, sy - radius - 14)
        data.nameText.Position = Vector2.new(sx, sy + radius + 5)
    end

    data.border.Visible   = true
    data.fill.Visible     = true
    data.ring.Visible     = true
    data.pingText.Visible = true
    data.nameText.Visible = true

    if tErrQ ~= data.lastTErr then
        data.lastTErr   = tErrQ
        data.fill.Color = Color3.new(tErrQ, 1 - tErrQ * 0.7, 0.2)
    end

    if now - data.lastPingUpdate >= 0.1 then
        data.lastPingUpdate = now
        data.pingText.Text  = string.format("%.0f ms", dt_ms)
    end

    -- Prediction line: real head → predicted orb
    local realSp, realInFront = worldToScreen(Vector3.new(curPos.X, curPos.Y + 2, curPos.Z))
    if realSp and realInFront then
        local from = Vector2.new(realSp.X, realSp.Y)
        local to   = Vector2.new(sx, sy)
        data.lineOutline.From = from; data.lineOutline.To = to
        data.line.From        = from; data.line.To        = to
        data.lineOutline.Visible = true
        data.line.Visible        = true
    else
        data.lineOutline.Visible = false
        data.line.Visible        = false
    end

    if now - lastDebugPrint > 3 then
        lastDebugPrint = now
        print(string.format("[OrbVis] %s | dt=%.0fms | err=%.2f",
            name, dt_ms, math.sqrt(eX*eX+eY*eY+eZ*eZ)))
    end
end

local accumulator = 0

RunService.RenderStepped:Connect(function(dt)
    accumulator = accumulator + dt
    if accumulator < UPDATE_INTERVAL then return end
    accumulator = accumulator - UPDATE_INTERVAL

    for name, player in next, activePlayers do
        updatePlayer(name, player)
    end
end)

_G.OrbVisToggle = function()
    for _, data in pairs(playerDrawings) do
        setAllVisible(data, not data.fill.Visible)
    end
    print("[OrbVisualizer] Toggled")
end

print("=== Predicted Position Visualizer v2.8 ===")
print("Clean flat orbs — green = accurate | red = off")
print("_G.OrbVisToggle() to toggle")
