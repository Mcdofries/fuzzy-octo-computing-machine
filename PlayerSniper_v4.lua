--[[
  ██████  ███    ██ ██ ██████  ███████ ██████  
  ██      ████   ██ ██ ██   ██ ██      ██   ██ 
  ███████ ██ ██  ██ ██ ██████  █████   ██████  
       ██ ██  ██ ██ ██ ██      ██      ██   ██ 
  ██████  ██   ████ ██ ██      ███████ ██   ██ 
  
  PLAYER SNIPER v4  |  Delta Mobile  |  2026
  ─────────────────────────────────────────────
  • Works with NO friend, NO join-on = ON
  • Uses Presence API + Token Batch Scan
  • TeleportAsync (new API, replaces deprecated call)
  • 6 fallback methods, parallel server scan
  • Compact draggable GUI
]]

-- ════════════════════════════════════════════════
--  SERVICES
-- ════════════════════════════════════════════════
local HS  = game:GetService("HttpService")
local TS  = game:GetService("TeleportService")
local PL  = game:GetService("Players")
local LP  = PL.LocalPlayer
local UIS = game:GetService("UserInputService")

-- ════════════════════════════════════════════════
--  HTTP WRAPPER  (Delta uses global "request")
-- ════════════════════════════════════════════════
local function http(method, url, body)
    local opts = {
        Url     = url,
        Method  = method,
        Headers = { ["Content-Type"] = "application/json",
                    ["Accept"]       = "application/json" },
    }
    if body then opts.Body = HS:JSONEncode(body) end

    local res
    -- Try Delta / most executors' global request()
    if type(request) == "function" then
        local ok, r = pcall(request, opts)
        if ok and r then res = r end
    end
    -- Fallback: http_request
    if not res and type(http_request) == "function" then
        local ok, r = pcall(http_request, opts)
        if ok and r then res = r end
    end
    -- Fallback: syn.request
    if not res and syn and type(syn.request) == "function" then
        local ok, r = pcall(syn.request, opts)
        if ok and r then res = r end
    end
    -- GET-only fallback: game:HttpGet
    if not res and method == "GET" then
        local ok, r = pcall(function()
            return { StatusCode = 200, Body = game:HttpGet(url, true) }
        end)
        if ok and r then res = r end
    end

    if res then
        local code = res.StatusCode or res.status_code or 0
        local bod  = res.Body or res.body or ""
        return code, bod
    end
    return 0, ""
end

local function GET(url)
    local c, b = http("GET", url)
    return (c == 200) and b or nil
end

local function POST(url, body)
    local c, b = http("POST", url, body)
    return b  -- return body regardless (presence API needs 200, thumbnails can be 200 too)
end

local function jd(s)
    if not s or s == "" then return nil end
    local ok, v = pcall(HS.JSONDecode, HS, s)
    return ok and v or nil
end

-- ════════════════════════════════════════════════
--  STATUS CALLBACK  (wired to GUI below)
-- ════════════════════════════════════════════════
local STATUS_CB = function(msg, col)
    print("[Sniper] " .. tostring(msg))
end
local C = {
    green  = Color3.fromRGB(80,  255, 130),
    yellow = Color3.fromRGB(255, 210, 50),
    red    = Color3.fromRGB(255, 80,  70),
    blue   = Color3.fromRGB(80,  200, 255),
    grey   = Color3.fromRGB(140, 140, 160),
}
local function s(msg, col) STATUS_CB(msg, col or C.grey) end
local function sg(msg) s("✓ "..msg, C.green)  end
local function sw(msg) s("⚠ "..msg, C.yellow) end
local function se(msg) s("✗ "..msg, C.red)    end
local function si(msg) s(msg,       C.blue)   end

-- ════════════════════════════════════════════════
--  STOP FLAG
-- ════════════════════════════════════════════════
local STOP = false

-- ════════════════════════════════════════════════
--  STEP 1 ─ Resolve username → userId
--  3 endpoints, stops at first success
-- ════════════════════════════════════════════════
local function resolveUser(username)
    si("Looking up: " .. username)

    -- 1A: POST /usernames/users
    local b1 = POST("https://users.roblox.com/v1/usernames/users",
        { usernames = {username}, excludeBannedUsers = false })
    local d1 = jd(b1)
    if d1 and d1.data and d1.data[1] then
        local u = d1.data[1]
        sg("Found "..u.name.." → ID "..u.id)
        return u.id, u.name
    end

    -- 1B: GET search
    local b2 = GET("https://users.roblox.com/v1/users/search?keyword="
        ..username:gsub(" ","+").."&limit=10")
    local d2 = jd(b2)
    if d2 and d2.data then
        for _, u in ipairs(d2.data) do
            if u.name:lower() == username:lower() then
                sg("Search found "..u.name.." → "..u.id)
                return u.id, u.name
            end
        end
    end

    -- 1C: Profile page scrape
    local b3 = GET("https://www.roblox.com/users/profile?username="..username)
    if b3 then
        local id = b3:match('"userId":(%d+)')
                or b3:match("Roblox%.userId%s*=%s*(%d+)")
        if id then
            sg("Scraped ID: "..id)
            return tonumber(id), username
        end
    end

    se("User not found: "..username)
    return nil, nil
end

-- ════════════════════════════════════════════════
--  STEP 2 ─ Get player's presence / current game
--  Returns { placeId, rootPlaceId, gameId } or nil
-- ════════════════════════════════════════════════
local function getPresence(userId)
    -- 2A: Main presence API
    local b = POST("https://presence.roblox.com/v1/presence/users",
        { userIds = {userId} })
    local d = jd(b)
    if d and d.userPresences and d.userPresences[1] then
        local p = d.userPresences[1]
        if p.userPresenceType == 2 then   -- 2 = InGame
            return {
                placeId     = p.placeId,
                rootPlaceId = p.rootPlaceId or p.placeId,
                gameId      = p.gameId,    -- direct server instance id (may be nil)
            }
        end
        if p.userPresenceType == 0 then
            return "offline"
        end
    end

    -- 2B: Old API endpoint
    local b2 = GET("https://api.roblox.com/users/"..userId.."/onlinestatus")
    local d2 = jd(b2)
    if d2 and d2.PlaceId and d2.PlaceId ~= 0 then
        return {
            placeId     = d2.PlaceId,
            rootPlaceId = d2.PlaceId,
            gameId      = d2.GameId,
        }
    end

    return nil
end

-- ════════════════════════════════════════════════
--  STEP 3 ─ Get target avatar headshot URL
--  Used to match tokens in server scan
-- ════════════════════════════════════════════════
local cachedAvatarUrl = nil
local function getAvatarUrl(userId)
    if cachedAvatarUrl then return cachedAvatarUrl end
    local b = GET(("https://thumbnails.roblox.com/v1/users/avatar-headshot"
        .."?userIds=%d&size=48x48&format=Png"):format(userId))
    local d = jd(b)
    if d and d.data and d.data[1] and d.data[1].imageUrl then
        cachedAvatarUrl = d.data[1].imageUrl
        return cachedAvatarUrl
    end
    return nil
end

-- ════════════════════════════════════════════════
--  STEP 4 ─ Scan all public servers, find player
--  Batch-posts all tokens per page in ONE request
--  Uses task.spawn for parallelism per server
-- ════════════════════════════════════════════════
local function scanServers(placeId, userId)
    cachedAvatarUrl = nil
    local avatarUrl = getAvatarUrl(userId)
    si("Scanning servers... avatar=" .. tostring(avatarUrl and avatarUrl:sub(1,40) or "?"))

    local cursor  = ""
    local page    = 0
    local found   = nil   -- server id when matched
    local checked = 0

    repeat
        if STOP then return nil end
        page = page + 1

        local url = ("https://games.roblox.com/v1/games/%d/servers/Public"
            .."?sortOrder=Asc&limit=100%s"):format(
                placeId,
                cursor ~= "" and ("&cursor=" .. cursor) or ""
            )

        local raw = GET(url)
        if not raw then
            sw("Server list fetch failed p"..page..", retrying...")
            task.wait(0.3)
            raw = GET(url)
            if not raw then break end
        end

        local data = jd(raw)
        if not data or not data.data or #data.data == 0 then break end

        s("Page "..page.." | "..#data.data.." servers | scanned "..checked)

        -- Parallel scan this page
        local pending = #data.data
        local pageDone = false

        for _, server in ipairs(data.data) do
            task.spawn(function()
                if STOP or pageDone then
                    pending -= 1
                    return
                end

                local tokens = server.playerTokens
                if not tokens or #tokens == 0 then
                    pending -= 1
                    return
                end

                -- Build batch request for ALL tokens in this server at once
                local batch = {}
                for i, tk in ipairs(tokens) do
                    batch[i] = {
                        requestId      = tostring(i),
                        token          = tk,
                        tokenHash      = tk,
                        thumbnailType  = "AvatarHeadShot",
                        size           = "48x48",
                        userId         = userId,
                    }
                end

                local res = POST("https://thumbnails.roblox.com/v1/batch", batch)
                local td  = jd(res)

                if td and td.data then
                    for _, entry in ipairs(td.data) do
                        local imgUrl = (entry.imageUrl or ""):gsub("?.*","")
                        local tgtUrl = avatarUrl and avatarUrl:gsub("?.*","") or ""

                        -- Match if both resolved + CDN url matches
                        if entry.state == "Completed"
                        and imgUrl ~= ""
                        and tgtUrl ~= ""
                        and imgUrl == tgtUrl
                        then
                            if not pageDone and not found then
                                found    = server.id
                                pageDone = true
                                sg("MATCH! Server: "..server.id)
                            end
                        end
                    end
                end

                checked += 1
                pending -= 1
            end)
        end

        -- Wait for this page's tasks
        local t0 = tick()
        while pending > 0 and not pageDone and not STOP do
            task.wait(0.04)
            if tick() - t0 > 15 then break end  -- safety timeout per page
        end

        if found or STOP then break end

        cursor = (data.nextPageCursor or "")
        if cursor == "" or cursor == "null" then break end

        task.wait(0.05)
    until false

    return found
end

-- ════════════════════════════════════════════════
--  STEP 5 ─ Teleport  (uses new TeleportAsync)
--  Falls back to old method if needed
-- ════════════════════════════════════════════════
local function doTeleport(placeId, serverId)
    sg("Teleporting → place:"..placeId.." srv:"..serverId)

    -- Method A: TeleportAsync (modern, correct way from LocalScript in exploits)
    local ok, err = pcall(function()
        local opts = Instance.new("TeleportOptions")
        opts.ServerInstanceId = serverId
        TS:TeleportAsync(placeId, {LP}, opts)
    end)
    if ok then return true end
    sw("TeleportAsync failed: "..tostring(err))

    -- Method B: TeleportToPlaceInstance (old, still works on most Delta builds)
    local ok2, err2 = pcall(function()
        TS:TeleportToPlaceInstance(placeId, serverId, LP)
    end)
    if ok2 then return true end
    sw("TeleportToPlaceInstance failed: "..tostring(err2))

    -- Method C: Teleport without player arg (LocalScript can omit player)
    local ok3, err3 = pcall(function()
        local opts = Instance.new("TeleportOptions")
        opts.ServerInstanceId = serverId
        TS:TeleportAsync(placeId, {LP})
    end)
    if ok3 then return true end

    -- Method D: plain Teleport to placeId (no specific server, last resort)
    local ok4 = pcall(function()
        TS:Teleport(placeId, LP)
    end)
    if ok4 then return true end

    se("All teleport methods failed.")
    return false
end

-- ════════════════════════════════════════════════
--  MAIN PIPELINE
-- ════════════════════════════════════════════════
local function snipe(username)
    STOP = false
    cachedAvatarUrl = nil

    si("━━ Sniping: "..username.." ━━")

    -- 1. Resolve username
    local userId, resolvedName = resolveUser(username)
    if not userId then return end

    -- 2. Poll presence until in-game
    local presence = nil
    for attempt = 1, 120 do
        if STOP then return end
        s("["..attempt.."/120] Checking presence...", C.grey)

        local p = getPresence(userId)
        if p == "offline" then
            sw("Offline. Retry "..attempt)
        elseif p then
            sg("In-game! Place:"..p.placeId)
            presence = p
            break
        else
            sw("No data. Retry "..attempt)
        end
        task.wait(1)
    end

    if not presence then
        se("Could not find player in-game after 120 tries.")
        return
    end
    if STOP then return end

    local placeId = presence.rootPlaceId or presence.placeId
    local gameId  = presence.gameId

    -- 3. FAST PATH: Presence gave us the server ID directly
    if gameId and gameId ~= ""
    and gameId ~= "00000000-0000-0000-0000-000000000000" then
        sg("Direct server ID from presence! Joining immediately...")
        task.wait(0.2)
        doTeleport(placeId, gameId)
        return
    end

    -- 4. SCAN PATH: find the server by token matching
    si("No direct ID. Starting server scan...")
    local serverId = scanServers(placeId, userId)

    if serverId and not STOP then
        sg("Server found! Joining: "..serverId)
        task.wait(0.2)
        doTeleport(placeId, serverId)
        return
    end

    if STOP then return end

    -- 5. RETRY PRESENCE: sometimes gameId appears on second look
    si("Retrying presence for direct ID (x10)...")
    for i = 1, 10 do
        if STOP then return end
        task.wait(1.2)
        local fresh = getPresence(userId)
        if fresh and type(fresh) == "table"
        and fresh.gameId and fresh.gameId ~= ""
        and fresh.gameId ~= "00000000-0000-0000-0000-000000000000" then
            sg("Got server ID on retry "..i.."!")
            doTeleport(placeId, fresh.gameId)
            return
        end
        s("Presence retry "..i.."/10", C.grey)
    end

    se("Could not find server. May be private/VIP.")
end

-- ════════════════════════════════════════════════
--  COMPACT GUI
-- ════════════════════════════════════════════════
local function buildGUI()
    -- Remove any old instance
    local pg = LP:WaitForChild("PlayerGui")
    local old = pg:FindFirstChild("__SnipeGUI")
    if old then old:Destroy() end

    local Screen = Instance.new("ScreenGui")
    Screen.Name            = "__SnipeGUI"
    Screen.ResetOnSpawn    = false
    Screen.DisplayOrder    = 1000
    Screen.IgnoreGuiInset  = true
    Screen.Parent          = pg

    -- Frame
    local Frame = Instance.new("Frame")
    Frame.Size             = UDim2.new(0, 260, 0, 122)
    Frame.Position         = UDim2.new(0, 10, 0, 10)
    Frame.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
    Frame.BorderSizePixel  = 0
    Frame.ClipsDescendants = true
    Frame.Parent           = Screen
    Instance.new("UICorner", Frame).CornerRadius = UDim.new(0, 10)

    -- Top accent line
    local Accent = Instance.new("Frame")
    Accent.Size             = UDim2.new(1, 0, 0, 2)
    Accent.BackgroundColor3 = Color3.fromRGB(0, 185, 255)
    Accent.BorderSizePixel  = 0
    Accent.Parent           = Frame

    -- Header bar (drag handle)
    local Header = Instance.new("Frame")
    Header.Size             = UDim2.new(1, 0, 0, 26)
    Header.Position         = UDim2.new(0, 0, 0, 2)
    Header.BackgroundColor3 = Color3.fromRGB(18, 18, 28)
    Header.BorderSizePixel  = 0
    Header.Parent           = Frame

    local Title = Instance.new("TextLabel")
    Title.Size                 = UDim2.new(1, -8, 1, 0)
    Title.Position             = UDim2.new(0, 8, 0, 0)
    Title.BackgroundTransparency = 1
    Title.Text                 = "⚡ PLAYER SNIPER v4"
    Title.TextColor3           = Color3.fromRGB(0, 200, 255)
    Title.TextSize             = 12
    Title.Font                 = Enum.Font.GothamBold
    Title.TextXAlignment       = Enum.TextXAlignment.Left
    Title.Parent               = Header

    -- Input
    local Input = Instance.new("TextBox")
    Input.Size               = UDim2.new(1, -14, 0, 26)
    Input.Position           = UDim2.new(0, 7, 0, 34)
    Input.BackgroundColor3   = Color3.fromRGB(20, 20, 32)
    Input.BorderSizePixel    = 0
    Input.PlaceholderText    = "Roblox username..."
    Input.PlaceholderColor3  = Color3.fromRGB(80, 80, 100)
    Input.Text               = ""
    Input.TextColor3         = Color3.fromRGB(240, 240, 255)
    Input.TextSize           = 13
    Input.Font               = Enum.Font.Gotham
    Input.ClearTextOnFocus   = false
    Input.Parent             = Frame
    Instance.new("UICorner", Input).CornerRadius = UDim.new(0, 6)

    -- SNIPE button
    local BtnSnipe = Instance.new("TextButton")
    BtnSnipe.Size              = UDim2.new(0, 142, 0, 24)
    BtnSnipe.Position          = UDim2.new(0, 7, 0, 66)
    BtnSnipe.BackgroundColor3  = Color3.fromRGB(0, 175, 255)
    BtnSnipe.BorderSizePixel   = 0
    BtnSnipe.Text              = "⚡ SNIPE"
    BtnSnipe.TextColor3        = Color3.fromRGB(255, 255, 255)
    BtnSnipe.TextSize          = 13
    BtnSnipe.Font              = Enum.Font.GothamBold
    BtnSnipe.Parent            = Frame
    Instance.new("UICorner", BtnSnipe).CornerRadius = UDim.new(0, 6)

    -- STOP button
    local BtnStop = Instance.new("TextButton")
    BtnStop.Size               = UDim2.new(0, 100, 0, 24)
    BtnStop.Position           = UDim2.new(0, 153, 0, 66)
    BtnStop.BackgroundColor3   = Color3.fromRGB(175, 35, 35)
    BtnStop.BorderSizePixel    = 0
    BtnStop.Text               = "✕ STOP"
    BtnStop.TextColor3         = Color3.fromRGB(255, 255, 255)
    BtnStop.TextSize           = 13
    BtnStop.Font               = Enum.Font.GothamBold
    BtnStop.Parent             = Frame
    Instance.new("UICorner", BtnStop).CornerRadius = UDim.new(0, 6)

    -- Status label
    local Status = Instance.new("TextLabel")
    Status.Size               = UDim2.new(1, -14, 0, 22)
    Status.Position           = UDim2.new(0, 7, 0, 96)
    Status.BackgroundTransparency = 1
    Status.Text               = "Ready — enter a username above"
    Status.TextColor3         = C.grey
    Status.TextSize           = 11
    Status.Font               = Enum.Font.Gotham
    Status.TextXAlignment     = Enum.TextXAlignment.Left
    Status.TextTruncate       = Enum.TextTruncate.AtEnd
    Status.Parent             = Frame

    -- Wire status callback
    STATUS_CB = function(msg, col)
        pcall(function()
            Status.Text       = tostring(msg)
            Status.TextColor3 = col or C.grey
        end)
        print("[Sniper] " .. tostring(msg))
    end

    -- ── Drag ──────────────────────────────────
    local drag, ds, dp
    Header.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            drag = true; ds = i.Position; dp = Frame.Position
        end
    end)
    Header.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            drag = false
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if drag and (i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - ds
            Frame.Position = UDim2.new(dp.X.Scale, dp.X.Offset+d.X,
                                       dp.Y.Scale, dp.Y.Offset+d.Y)
        end
    end)

    -- ── Buttons ───────────────────────────────
    local running = false

    BtnSnipe.MouseButton1Click:Connect(function()
        if running then return end
        local uname = Input.Text:match("^%s*(.-)%s*$")
        if uname == "" then
            Status.Text      = "Enter a username first!"
            Status.TextColor3 = C.yellow
            return
        end
        running = true
        STOP    = false
        BtnSnipe.Text             = "⏳ Sniping..."
        BtnSnipe.BackgroundColor3 = Color3.fromRGB(0, 100, 180)

        task.spawn(function()
            local ok, err = pcall(snipe, uname)
            if not ok then
                STATUS_CB("Error: "..tostring(err), C.red)
            end
            running = false
            BtnSnipe.Text             = "⚡ SNIPE"
            BtnSnipe.BackgroundColor3 = Color3.fromRGB(0, 175, 255)
        end)
    end)

    BtnStop.MouseButton1Click:Connect(function()
        STOP    = true
        running = false
        BtnSnipe.Text             = "⚡ SNIPE"
        BtnSnipe.BackgroundColor3 = Color3.fromRGB(0, 175, 255)
        STATUS_CB("Stopped.", C.red)
    end)
end

-- ════════════════════════════════════════════════
--  LAUNCH
-- ════════════════════════════════════════════════
buildGUI()
print("[PlayerSniper v4] Loaded. GUI ready.")
