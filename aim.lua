-- i stole this 
loadstring(game:HttpGet("https://raw.githubusercontent.com/debrainers/scripts/refs/heads/main/ArcaneUiNOTMINE"))()
repeat wait() until Arcane

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local camera      = Workspace.CurrentCamera

local Window = Arcane:CreateWindow("MeowWare", Vector2.new(540, 560), "Default")
Window:CreateTabSection("Aimbot")
local MainTab   = Window:CreateTab("Main")
local TargetTab = Window:CreateTab("Target")

local cfg = {
    enabled   = false,
    teamCheck = false,
    fov       = 150,
    sens      = 0.5,
    sensClose = 0.3,
    sensFar   = 1.4,
    sensDist  = 100,
    smooth    = 0.12,
    smoothFar = 0.60,
    smoothDist= 80,
    predict   = true,
    latency   = 0.06,
    part      = "Head",
    key       = 0x02,
    sticky    = true,
}

local lockedTarget = nil
local velX, velY   = 0, 0

local fovCircle = Drawing.new("Circle")
fovCircle.Filled      = false
fovCircle.Thickness   = 1.5
fovCircle.Color       = Color3.fromRGB(255,255,255)
fovCircle.Transparency= 0.5
fovCircle.NumSides    = 64
fovCircle.Visible     = false

-- PREDICTION - adgods

local history = {}
local HIST_SIZE = 60

local function getHist(name)
    if not history[name] then
        history[name] = { buf = {}, head = 0, size = 0 }
        for i = 1, HIST_SIZE do
            history[name].buf[i] = { t=0, px=0,py=0,pz=0, vx=0,vy=0,vz=0, mx=0,my=0,mz=0, yaw=0, yawRate=0 }
        end
    end
    return history[name]
end

local function pushHist(h, pos, vel, mass)
    local hidx = (h.head % HIST_SIZE) + 1
    local s = h.buf[hidx]
    mass = mass or 1
    if mass <= 0 then mass = 1 end

    local now = tick()
    local lv = CFrame.lookAt(pos, pos + vel).LookVector
    local yaw = math.atan2(-lv.X, -lv.Z)
    local yawRate = 0

    if h.size > 0 then
        local prev = h.buf[(h.head - 1) % HIST_SIZE + 1]
        local dt = now - prev.t
        if dt > 0 then
            local diff = (yaw - prev.yaw) % (math.pi*2)
            if diff > math.pi then diff = diff - math.pi*2 end
            yawRate = diff / dt
        end
    end

    s.t = now; s.px = pos.X; s.py = pos.Y; s.pz = pos.Z
    s.vx = vel.X; s.vy = vel.Y; s.vz = vel.Z
    s.mx = vel.X*mass; s.my = vel.Y*mass; s.mz = vel.Z*mass
    s.yaw = yaw; s.yawRate = yawRate

    h.head = hidx
    if h.size < HIST_SIZE then h.size = h.size + 1 end
    return now
end

local function getRecentData(h)
    if h.size < 2 then return nil end
    return h.buf[h.head]
end

-- MROW
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

local function getAimTime(pixelDist)
    local effectiveSpeed = cfg.sens * 1500 * (1 - cfg.smooth)
    if effectiveSpeed < 50 then effectiveSpeed = 50 end
    local t = pixelDist / effectiveSpeed
    return math.clamp(t, 0, 0.4) 
end

local function predictPos(target, extraDt)
    if not target then return nil end
    local char = target.Character
    if not char then return nil end
    local part = char:FindFirstChild(cfg.part) or char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
    if not part then return nil end

    if not cfg.predict then return part.Position end

    local h = getHist(target.Name)
    local now = pushHist(h, part.Position, part.AssemblyLinearVelocity, part.AssemblyMass)

    if h.size < 4 then return part.Position end

    local recent = getRecentData(h)
    if not recent then return part.Position end

    local dt = cfg.latency + (extraDt or 0)
    if dt < 0.001 then return part.Position end

    local curPos = part.Position
    local curVel = part.AssemblyLinearVelocity
    local mass = part.AssemblyMass or 1
    if mass <= 0 then mass = 1 end

    local vx, vy, vz = predictXYZ(
        curVel.X, curVel.Y, curVel.Z,
        curVel.X * mass, curVel.Y * mass, curVel.Z * mass,
        recent.yawRate, dt
    )

    return Vector3.new(curPos.X + vx, curPos.Y + vy, curPos.Z + vz)
end

local function w2s(pos)
    if not pos then return nil, false end
    local sp, onScreen = WorldToScreen(pos)
    if sp and sp.X and sp.Y then return sp, onScreen == true end
    return nil, false
end

local function dist2(a, b)
    local dx, dy = a.X - b.X, a.Y - b.Y
    return math.sqrt(dx*dx + dy*dy)
end

local function isTeam(plr)
    if not cfg.teamCheck then return false end
    return plr.Team == localPlayer.Team
end

local function getPart(char)
    if not char then return nil end
    return char:FindFirstChild(cfg.part) or char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
end

local function isAlive(plr)
    if not plr then return false end
    local char = plr.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    return hum and hum.Health > 0
end

local function findTarget()
    local best, bestDist = nil, 9e9
    local center = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr == localPlayer then continue end
        if isTeam(plr) then continue end

        local char = plr.Character
        local part = getPart(char)
        if not part then continue end

        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then continue end

        local sp, on = w2s(part.Position)
        if not on or not sp then continue end

        local d = dist2(sp, center)
        if d > cfg.fov then continue end
        if d < bestDist then bestDist = d; best = plr end
    end

    return best
end

local function aim(targetPos)
    if not targetPos then return end
    local sp, on = w2s(targetPos)
    if not on or not sp then return end

    local cx = camera.ViewportSize.X / 2
    local cy = camera.ViewportSize.Y / 2

    local dx = sp.X - cx
    local dy = sp.Y - cy
    local pixelDist = math.sqrt(dx*dx + dy*dy)

    local t = math.clamp(pixelDist / cfg.smoothDist, 0, 1)
    local smoothing = cfg.smooth + (cfg.smoothFar - cfg.smooth) * t

    local st = math.clamp(pixelDist / cfg.sensDist, 0, 1)
    local sensMult = cfg.sensClose + (cfg.sensFar - cfg.sensClose) * st
    local finalSens = cfg.sens * sensMult

    local rawDx = dx * finalSens
    local rawDy = dy * finalSens

    local stepX = rawDx * (1 - smoothing)
    local stepY = rawDy * (1 - smoothing)

    velX = stepX * 0.6 + velX * 0.4
    velY = stepY * 0.6 + velY * 0.4

    if math.abs(velX) < 0.5 and math.abs(velY) < 0.5 and pixelDist < 5 then
        velX = 0
        velY = 0
        return
    end

    mousemoverel(velX, velY)
end

RunService.Heartbeat:Connect(function()
    if cfg.enabled then
        local mx = localPlayer:GetMouse().X
        local my = localPlayer:GetMouse().Y
        if mx and my then
            fovCircle.Position = Vector2.new(mx, my)
            fovCircle.Radius = cfg.fov
            fovCircle.Visible = true
        else
            fovCircle.Visible = false
        end
    else
        fovCircle.Visible = false
    end

    if not cfg.enabled or not iskeypressed(cfg.key) then
        lockedTarget = nil
        velX = 0
        velY = 0
        return
    end

    if cfg.sticky and lockedTarget and isAlive(lockedTarget) then
    else
        lockedTarget = findTarget()
    end

    if not lockedTarget then
        velX = velX * 0.5
        velY = velY * 0.5
        if math.abs(velX) < 0.5 then velX = 0 end
        if math.abs(velY) < 0.5 then velY = 0 end
        return
    end

    local char = lockedTarget.Character
    local part = getPart(char)
    local aimTime = 0
    if part then
        local curSp, curOn = w2s(part.Position)
        if curOn and curSp then
            local cx = camera.ViewportSize.X / 2
            local cy = camera.ViewportSize.Y / 2
            local cdx = curSp.X - cx
            local cdy = curSp.Y - cy
            local curPixelDist = math.sqrt(cdx*cdx + cdy*cdy)
            aimTime = getAimTime(curPixelDist)
        end
    end

    -- predict where target will be by the time our mouse actually arrives
    local aimPos = predictPos(lockedTarget, aimTime)
    if aimPos then
        aim(aimPos)
    end
end)

local Main = Window:CreateSection("Aimbot", "Main")

Main:AddToggle("Enabled", false, function(v) cfg.enabled = v end)
Main:AddKeybind("Aim Key", "Mouse2", function() end)

Main:AddToggle("Sticky", true, function(v) cfg.sticky = v end)

Main:AddSlider("FOV", {
    Min = 30, Max = 500, Default = 150,
    Callback = function(v) cfg.fov = v end
})

Main:AddSlider("Sensitivity", {
    Min = 10, Max = 300, Default = 50,
    Callback = function(v) cfg.sens = v / 100 end
})

local Tgt = Window:CreateSection("Targeting", "Target")

Tgt:AddToggle("Team Check", false, function(v) cfg.teamCheck = v end)

Tgt:AddDropdown("Target Part", {"Head", "Torso", "HumanoidRootPart"}, "Head", function(v)
    cfg.part = v
end)

local Sens = Window:CreateSection("Distance Sensitivity", "Target")

Sens:AddSlider("Sens Close", {
    Min = 5, Max = 100, Default = 20,
    Callback = function(v) cfg.sensClose = v / 100 end
})

Sens:AddSlider("Sens Far", {
    Min = 50, Max = 300, Default = 70,
    Callback = function(v) cfg.sensFar = v / 100 end
})

Sens:AddSlider("Sens Distance", {
    Min = 20, Max = 300, Default = 100,
    Callback = function(v) cfg.sensDist = v end
})

local Smth = Window:CreateSection("Smoothing", "Target")

Smth:AddSlider("Smooth Close", {
    Min = 0, Max = 50, Default = 12,
    Callback = function(v) cfg.smooth = v / 100 end
})

Smth:AddSlider("Smooth Far", {
    Min = 10, Max = 95, Default = 60,
    Callback = function(v) cfg.smoothFar = v / 100 end
})

Smth:AddSlider("Smooth Distance", {
    Min = 20, Max = 300, Default = 80,
    Callback = function(v) cfg.smoothDist = v end
})

local Prd = Window:CreateSection("Prediction", "Target")

Prd:AddToggle("Prediction", true, function(v) cfg.predict = v end)

Prd:AddSlider("Latency (ms)", {
    Min = 10, Max = 200, Default = 60,
    Callback = function(v) cfg.latency = v / 1000 end
})

Window:Finalize()

print("Aimbot loaded")
