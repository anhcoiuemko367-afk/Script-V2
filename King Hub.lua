--[[
    ⚡ KING HUB V2 | Steal An Egg
    UI: Fluent | Chạy bằng executor hỗ trợ HttpGet
    Lưu ý: Tên folder trong game có thể khác -> chỉnh trong bảng CONFIG bên dưới
    hoặc dùng nút "Quét cấu trúc game" ở tab Cài Đặt để tìm tên đúng.
]]

if getgenv and getgenv().KingHubLoaded then
    getgenv().KingHubUnload()
end

-- ============ LOAD THƯ VIỆN ============
local Fluent = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"))()
local InterfaceManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"))()

-- ============ SERVICES ============
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local LocalPlayer = Players.LocalPlayer

-- ============ CONFIG (CHỈNH THEO GAME) ============
local CONFIG = {
    EggFolders   = { "Eggs", "DroppedEggs", "SpawnedEggs" }, -- folder chứa trứng trong Workspace
    EggKeywords  = { "egg" },                                 -- fallback: tìm vật thể có tên chứa từ này
    SellFolders  = { "Bases", "Unlocks", "Plots" },           -- folder chứa base người chơi
    SellNames    = { "sellpart", "sell", "deposit", "collect" },
    ScanInterval = 2,                                         -- giây giữa các lần quét trứng (giảm lag)
}

-- ============ STATE ============
local State = {
    Connections = {},
    ESP = {},
    EggsCollected = 0,
    StartTime = os.clock(),
    Saved = {},          -- vị trí đã lưu { [tên] = CFrame }
    Busy = false,
    Unloaded = false,
    EggCache = {},
    LastScan = 0,
}

local function connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(State.Connections, c)
    return c
end

-- ============ HÀM TIỆN ÍCH ============
local function getChar() return LocalPlayer.Character end
local function getHRP()
    local c = getChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHum()
    local c = getChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function getPos(inst)
    if inst:IsA("BasePart") then return inst.Position end
    if inst:IsA("Model") then
        local ok, p = pcall(function() return inst:GetPivot().Position end)
        if ok then return p end
    end
end

local function nameMatches(name, list)
    name = string.lower(name)
    for _, k in ipairs(list) do
        if string.find(name, k, 1, true) then return true end
    end
    return false
end

local function notify(title, content, dur)
    pcall(function()
        Fluent:Notify({ Title = title, Content = content, Duration = dur or 3 })
    end)
end

-- ============ DỊCH CHUYỂN MƯỢT (TWEEN) ============
local function TeleportTo(targetCFrame, speed)
    local hrp = getHRP()
    if not hrp then return false end
    speed = math.max(speed or 60, 10)
    local distance = (hrp.Position - targetCFrame.Position).Magnitude
    local duration = math.max(distance / speed, 0.05)

    local bv = Instance.new("BodyVelocity")
    bv.Velocity = Vector3.zero
    bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
    bv.Parent = hrp

    local tween = TweenService:Create(hrp, TweenInfo.new(duration, Enum.EasingStyle.Linear), { CFrame = targetCFrame })
    tween:Play()
    tween.Completed:Wait()
    bv:Destroy()
    return true
end

-- ============ TÌM TRỨNG ============
local function scanEggs()
    local found = {}

    -- Ưu tiên folder đã cấu hình
    for _, folderName in ipairs(CONFIG.EggFolders) do
        local folder = workspace:FindFirstChild(folderName)
        if folder then
            for _, egg in ipairs(folder:GetChildren()) do
                if getPos(egg) then table.insert(found, egg) end
            end
        end
    end

    -- Fallback: quét theo từ khóa (chỉ khi folder không có gì)
    if #found == 0 then
        for _, obj in ipairs(workspace:GetDescendants()) do
            if (obj:IsA("BasePart") or obj:IsA("Model"))
                and nameMatches(obj.Name, CONFIG.EggKeywords)
                and not obj:IsDescendantOf(getChar() or workspace)
                and (obj:FindFirstChildWhichIsA("ProximityPrompt", true) or obj:FindFirstChildWhichIsA("TouchTransmitter", true)) then
                table.insert(found, obj)
            end
        end
    end
    return found
end

local function getEggs()
    if os.clock() - State.LastScan > CONFIG.ScanInterval then
        State.EggCache = scanEggs()
        State.LastScan = os.clock()
    end
    return State.EggCache
end

local function nearestEgg()
    local hrp = getHRP()
    if not hrp then return nil end
    local best, bestDist = nil, math.huge
    for _, egg in ipairs(getEggs()) do
        if egg.Parent then
            local p = getPos(egg)
            if p then
                local d = (hrp.Position - p).Magnitude
                if d < bestDist then best, bestDist = egg, d end
            end
        end
    end
    return best, bestDist
end

-- Kích hoạt nhặt: ProximityPrompt hoặc Touch
local function interact(egg)
    local hrp = getHRP()
    if not hrp then return end
    local prompt = egg:FindFirstChildWhichIsA("ProximityPrompt", true)
    if prompt and fireproximityprompt then
        pcall(fireproximityprompt, prompt)
    end
    local part = egg:IsA("BasePart") and egg or egg:FindFirstChildWhichIsA("BasePart", true)
    if part and firetouchinterest then
        pcall(function()
            firetouchinterest(hrp, part, 0)
            task.wait()
            firetouchinterest(hrp, part, 1)
        end)
    end
end

-- ============ TÌM BASE / KHU BÁN ============
local function findSellTarget()
    for _, folderName in ipairs(CONFIG.SellFolders) do
        local folder = workspace:FindFirstChild(folderName)
        if folder then
            local mine = folder:FindFirstChild(LocalPlayer.Name)
            if not mine then
                -- thử tìm base có attribute Owner trùng tên/UserId
                for _, b in ipairs(folder:GetChildren()) do
                    local owner = b:GetAttribute("Owner") or b:GetAttribute("OwnerName") or b:GetAttribute("OwnerId")
                    if owner == LocalPlayer.Name or owner == LocalPlayer.UserId then mine = b break end
                end
            end
            if mine then
                for _, d in ipairs(mine:GetDescendants()) do
                    if (d:IsA("BasePart") or d:IsA("Model")) and nameMatches(d.Name, CONFIG.SellNames) then
                        return d
                    end
                end
                return mine
            end
        end
    end
end

-- ============ CỬA SỔ UI ============
local Window = Fluent:CreateWindow({
    Title = "⚡ KING HUB V2",
    SubTitle = "Steal An Egg • Premium Edition",
    TabWidth = 160,
    Size = UDim2.fromOffset(600, 480),
    Acrylic = false,
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.RightControl,
})

local Tabs = {
    Info     = Window:AddTab({ Title = "Thông Tin", Icon = "info" }),
    Main     = Window:AddTab({ Title = "Auto Farm", Icon = "egg" }),
    Visual   = Window:AddTab({ Title = "Hiển Thị", Icon = "eye" }),
    Player   = Window:AddTab({ Title = "Nhân Vật", Icon = "user" }),
    Teleport = Window:AddTab({ Title = "Dịch Chuyển", Icon = "map-pin" }),
    Settings = Window:AddTab({ Title = "Cài Đặt", Icon = "settings" }),
}
local Options = Fluent.Options

-- ---------- TAB THÔNG TIN ----------
local StatusParagraph = Tabs.Info:AddParagraph({
    Title = "📊 Trạng thái",
    Content = "Đang khởi động...",
})
Tabs.Info:AddParagraph({
    Title = "📖 Hướng dẫn nhanh",
    Content = "1. Vào tab Auto Farm, bật Auto Nhặt Trứng.\n2. Chỉnh tốc độ 50-70 để an toàn.\n3. Bật Auto Bán nếu muốn tự về base.\n4. Nhấn Right Ctrl để ẩn/hiện menu.",
})

-- ---------- TAB AUTO FARM ----------
Tabs.Main:AddSection("Nhặt trứng")
Tabs.Main:AddToggle("AutoEgg", { Title = "Auto Nhặt Trứng", Description = "Tự bay tới trứng gần nhất", Default = false })
Tabs.Main:AddSlider("TweenSpeed", {
    Title = "Tốc độ di chuyển",
    Description = "An toàn: 50-70. Cao quá dễ bị kick!",
    Default = 60, Min = 30, Max = 150, Rounding = 0,
})
Tabs.Main:AddSlider("MaxDistance", {
    Title = "Khoảng cách tối đa (studs)",
    Description = "Chỉ nhặt trứng trong phạm vi này",
    Default = 500, Min = 50, Max = 3000, Rounding = 0,
})
Tabs.Main:AddSlider("PickDelay", {
    Title = "Độ trễ sau mỗi lần nhặt (giây)",
    Default = 0.2, Min = 0.05, Max = 2, Rounding = 2,
})

Tabs.Main:AddSection("Bán / Cất trứng")
Tabs.Main:AddToggle("AutoSell", { Title = "Tự động bán / cất vào Base", Default = false })
Tabs.Main:AddSlider("SellEvery", {
    Title = "Bán sau mỗi (giây)",
    Default = 30, Min = 5, Max = 300, Rounding = 0,
})
Tabs.Main:AddButton({
    Title = "Về Base / Khu bán ngay",
    Callback = function()
        local t = findSellTarget()
        if t then
            local p = getPos(t)
            if p then TeleportTo(CFrame.new(p + Vector3.new(0, 3, 0)), Options.TweenSpeed.Value) end
        else
            notify("Không tìm thấy", "Chưa tìm được base. Dùng nút Quét ở tab Cài Đặt.", 4)
        end
    end,
})

-- Vòng lặp Auto Nhặt
task.spawn(function()
    while not State.Unloaded do
        task.wait(0.15)
        if Options.AutoEgg and Options.AutoEgg.Value and not State.Busy then
            local ok, err = pcall(function()
                local egg, dist = nearestEgg()
                if egg and dist <= Options.MaxDistance.Value then
                    State.Busy = true
                    local p = getPos(egg)
                    if p then
                        TeleportTo(CFrame.new(p + Vector3.new(0, 2, 0)), Options.TweenSpeed.Value)
                        interact(egg)
                        State.EggsCollected += 1
                        task.wait(Options.PickDelay.Value)
                    end
                    State.Busy = false
                end
            end)
            if not ok then State.Busy = false end
        end
    end
end)

-- Vòng lặp Auto Bán
task.spawn(function()
    local last = os.clock()
    while not State.Unloaded do
        task.wait(1)
        if Options.AutoSell and Options.AutoSell.Value and not State.Busy
            and os.clock() - last >= Options.SellEvery.Value then
            pcall(function()
                local t = findSellTarget()
                if t then
                    State.Busy = true
                    local p = getPos(t)
                    if p then
                        TeleportTo(CFrame.new(p + Vector3.new(0, 3, 0)), Options.TweenSpeed.Value)
                        interact(t)
                    end
                    State.Busy = false
                end
            end)
            State.Busy = false
            last = os.clock()
        end
    end
end)

-- ---------- TAB HIỂN THỊ (ESP) ----------
Tabs.Visual:AddToggle("EggESP", { Title = "ESP Trứng", Description = "Highlight + khoảng cách", Default = false })

local function clearESP()
    for obj, data in pairs(State.ESP) do
        pcall(function() data.hl:Destroy() end)
        pcall(function() data.bb:Destroy() end)
        State.ESP[obj] = nil
    end
end

task.spawn(function()
    while not State.Unloaded do
        task.wait(1)
        if Options.EggESP and Options.EggESP.Value then
            pcall(function()
                local hrp = getHRP()
                for _, egg in ipairs(getEggs()) do
                    if egg.Parent and not State.ESP[egg] then
                        local hl = Instance.new("Highlight")
                        hl.FillColor = Color3.fromRGB(255, 200, 0)
                        hl.OutlineColor = Color3.fromRGB(255, 255, 255)
                        hl.FillTransparency = 0.5
                        hl.Adornee = egg
                        hl.Parent = egg

                        local adorn = egg:IsA("BasePart") and egg or egg:FindFirstChildWhichIsA("BasePart", true)
                        local bb = Instance.new("BillboardGui")
                        bb.Size = UDim2.fromOffset(100, 24)
                        bb.AlwaysOnTop = true
                        bb.StudsOffset = Vector3.new(0, 3, 0)
                        bb.Adornee = adorn
                        bb.Parent = egg
                        local lbl = Instance.new("TextLabel")
                        lbl.Size = UDim2.fromScale(1, 1)
                        lbl.BackgroundTransparency = 1
                        lbl.TextColor3 = Color3.fromRGB(255, 230, 120)
                        lbl.TextStrokeTransparency = 0
                        lbl.TextScaled = true
                        lbl.Font = Enum.Font.GothamBold
                        lbl.Parent = bb

                        State.ESP[egg] = { hl = hl, bb = bb, lbl = lbl }
                    end
                end
                for egg, data in pairs(State.ESP) do
                    if not egg.Parent then
                        pcall(function() data.hl:Destroy() end)
                        pcall(function() data.bb:Destroy() end)
                        State.ESP[egg] = nil
                    elseif hrp then
                        local p = getPos(egg)
                        if p then data.lbl.Text = "🥚 " .. math.floor((hrp.Position - p).Magnitude) .. "m" end
                    end
                end
            end)
        else
            if next(State.ESP) then clearESP() end
        end
    end
end)

-- ---------- TAB NHÂN VẬT ----------
Tabs.Player:AddSlider("WalkSpeed", { Title = "Tốc độ chạy", Default = 16, Min = 16, Max = 120, Rounding = 0 })
Tabs.Player:AddSlider("JumpPower", { Title = "Sức nhảy", Default = 50, Min = 50, Max = 200, Rounding = 0 })
Tabs.Player:AddToggle("ApplyStats", { Title = "Áp dụng tốc độ / sức nhảy", Default = false })
Tabs.Player:AddToggle("InfJump", { Title = "Nhảy vô hạn", Default = false })
Tabs.Player:AddToggle("Noclip", { Title = "Xuyên tường (Noclip)", Default = false })

connect(RunService.Heartbeat, function()
    local hum = getHum()
    if hum and Options.ApplyStats and Options.ApplyStats.Value then
        hum.WalkSpeed = Options.WalkSpeed.Value
        hum.UseJumpPower = true
        hum.JumpPower = Options.JumpPower.Value
    end
end)

connect(UserInputService.JumpRequest, function()
    if Options.InfJump and Options.InfJump.Value then
        local hum = getHum()
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end)

connect(RunService.Stepped, function()
    if (Options.Noclip and Options.Noclip.Value) or State.Busy then
        local c = getChar()
        if c then
            for _, part in ipairs(c:GetDescendants()) do
                if part:IsA("BasePart") then part.CanCollide = false end
            end
        end
    end
end)

-- ---------- TAB DỊCH CHUYỂN ----------
Tabs.Teleport:AddSection("Vị trí đã lưu")
local SavedDropdown = Tabs.Teleport:AddDropdown("SavedPos", {
    Title = "Chọn vị trí", Values = {}, Multi = false, Default = nil,
})
local posCounter = 0
local function refreshSaved()
    local names = {}
    for n in pairs(State.Saved) do table.insert(names, n) end
    table.sort(names)
    SavedDropdown:SetValues(names)
end
Tabs.Teleport:AddButton({
    Title = "💾 Lưu vị trí hiện tại",
    Callback = function()
        local hrp = getHRP()
        if not hrp then return end
        posCounter += 1
        local name = "Vị trí " .. posCounter
        State.Saved[name] = hrp.CFrame
        refreshSaved()
        SavedDropdown:SetValue(name)
        notify("Đã lưu", name, 2)
    end,
})
Tabs.Teleport:AddButton({
    Title = "🚀 Bay tới vị trí đã chọn",
    Callback = function()
        local cf = State.Saved[Options.SavedPos.Value]
        if cf then TeleportTo(cf, Options.TweenSpeed.Value) end
    end,
})

Tabs.Teleport:AddSection("Người chơi")
local PlayerDropdown = Tabs.Teleport:AddDropdown("TargetPlayer", {
    Title = "Chọn người chơi", Values = {}, Multi = false, Default = nil,
})
local function refreshPlayers()
    local names = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then table.insert(names, p.Name) end
    end
    PlayerDropdown:SetValues(names)
end
refreshPlayers()
connect(Players.PlayerAdded, refreshPlayers)
connect(Players.PlayerRemoving, function() task.defer(refreshPlayers) end)
Tabs.Teleport:AddButton({
    Title = "Bay tới người chơi",
    Callback = function()
        local target = Players:FindFirstChild(Options.TargetPlayer.Value or "")
        local thrp = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
        if thrp then TeleportTo(thrp.CFrame * CFrame.new(0, 0, 3), Options.TweenSpeed.Value) end
    end,
})

-- ---------- TAB CÀI ĐẶT ----------
Tabs.Settings:AddSection("Hệ thống")
Tabs.Settings:AddToggle("AntiAFK", { Title = "Chống treo máy (Anti-AFK)", Default = true })
connect(LocalPlayer.Idled, function()
    if Options.AntiAFK and Options.AntiAFK.Value then
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
    end
end)

Tabs.Settings:AddToggle("FPSBoost", {
    Title = "Tăng FPS (giảm đồ họa)", Default = false,
    Callback = function(v)
        pcall(function()
            if v then
                Lighting.GlobalShadows = false
                Lighting.FogEnd = 9e9
                settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
            else
                Lighting.GlobalShadows = true
                settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic
            end
        end)
    end,
})

Tabs.Settings:AddButton({
    Title = "Vào lại server (Rejoin)",
    Callback = function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end,
})
Tabs.Settings:AddButton({
    Title = "Đổi server (Server Hop)",
    Callback = function()
        pcall(function()
            local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)
            local data = HttpService:JSONDecode(game:HttpGet(url))
            for _, s in ipairs(data.data) do
                if s.id ~= game.JobId and s.playing < s.maxPlayers then
                    TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, LocalPlayer)
                    return
                end
            end
            notify("Server Hop", "Không tìm được server phù hợp.", 3)
        end)
    end,
})

Tabs.Settings:AddSection("Công cụ chỉnh script")
Tabs.Settings:AddButton({
    Title = "🔍 Quét cấu trúc game (in ra F9)",
    Description = "Liệt kê folder/vật thể có chữ egg, sell, base",
    Callback = function()
        local kw = { "egg", "sell", "base", "plot", "unlock" }
        print("===== KING HUB SCAN =====")
        for _, child in ipairs(workspace:GetChildren()) do
            if nameMatches(child.Name, kw) then
                print("[Workspace]", child.Name, child.ClassName, "(" .. #child:GetChildren() .. " con)")
            end
        end
        print("===== HẾT =====")
        notify("Quét xong", "Mở console (F9) để xem kết quả.", 4)
    end,
})
Tabs.Settings:AddButton({
    Title = "❌ Tắt hẳn script (Unload)",
    Callback = function() getgenv().KingHubUnload() end,
})

-- ============ CẬP NHẬT TRẠNG THÁI ============
task.spawn(function()
    while not State.Unloaded do
        task.wait(1)
        local t = math.floor(os.clock() - State.StartTime)
        local txt = string.format(
            "⏱ Thời gian chạy: %02d:%02d:%02d\n🥚 Đã nhặt: %d\n🔎 Trứng trong map: %d\n⚙ Auto Farm: %s | Auto Bán: %s",
            t // 3600, (t % 3600) // 60, t % 60,
            State.EggsCollected,
            #getEggs(),
            (Options.AutoEgg and Options.AutoEgg.Value) and "BẬT" or "TẮT",
            (Options.AutoSell and Options.AutoSell.Value) and "BẬT" or "TẮT"
        )
        pcall(function() StatusParagraph:SetDesc(txt) end)
    end
end)

-- ============ UNLOAD ============
if getgenv then
    getgenv().KingHubLoaded = true
    getgenv().KingHubUnload = function()
        State.Unloaded = true
        for _, c in ipairs(State.Connections) do pcall(function() c:Disconnect() end) end
        clearESP()
        pcall(function() Fluent:Destroy() end)
        getgenv().KingHubLoaded = false
    end
end

-- ============ LƯU CẤU HÌNH ============
SaveManager:SetLibrary(Fluent)
InterfaceManager:SetLibrary(Fluent)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "SavedPos", "TargetPlayer" })
InterfaceManager:SetFolder("KingHubConfig")
SaveManager:SetFolder("KingHubConfig/StealAnEgg")
InterfaceManager:BuildInterfaceSection(Tabs.Settings)
SaveManager:BuildConfigSection(Tabs.Settings)

Window:SelectTab(1)
notify("KING HUB V2", "Đã tải xong! Nhấn Right Ctrl để ẩn/hiện menu.", 5)
SaveManager:LoadAutoloadConfig()
