local API_URL = "https://rochess-gateway.vercel.app/api/analyze"
local STRENGTH = "high"
local PLAY_AS = "Black" -- Change to "White" when playing White.
local SCAN_DELAY = 0.2
local board, piecesFolder
print("[Workspace Chess] Starting script; looking for Workspace.Board and Workspace.Pieces...")
for _ = 1, 60 do
    board = workspace:FindFirstChild("Board")
    piecesFolder = workspace:FindFirstChild("Pieces")
    if board and piecesFolder then
        break
    end
    task.wait(0.5)
end
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local arrows = {}
local arrowFrom, arrowTo
local previous = {}
local whiteToMove = true
local newGameRequested = false

if UI and UI.AddTab then
    UI.AddTab("RoChess AI", function(tab)
        local settings = tab:Section("Game Settings", "Left")
        settings:Combo("rochess_play_as", "Play as", {"White", "Black", "Any"}, PLAY_AS == "White" and 0 or 1, function(_, text)
            PLAY_AS = text
        end)
        settings:Combo("rochess_strength", "Strength", {"Low", "Medium", "High"}, 2, function(_, text)
            STRENGTH = string.lower(text)
        end)
        settings:Button("New Game", function()
            newGameRequested = true
        end)
        settings:Text("Green arrow = recommended move")
    end)
end

if not board or not piecesFolder then
    error("Workspace chess board not found. Expected workspace.Board and workspace.Pieces")
end

local function squareName(file, rank)
    return string.char(96 + file) .. tostring(rank)
end

local function positionToSquare(position)
    local first = board:FindFirstChild("1,1")
    local filePart = board:FindFirstChild("2,1")
    local rankPart = board:FindFirstChild("1,2")
    if not first or not filePart or not rankPart then return nil end
    local fileStep = filePart.Position.X - first.Position.X
    local rankStep = rankPart.Position.Z - first.Position.Z
    if math.abs(fileStep) < 0.01 or math.abs(rankStep) < 0.01 then return nil end
    local file = math.floor((position.X - first.Position.X) / fileStep + 0.5) + 1
    local rank = math.floor((position.Z - first.Position.Z) / rankStep + 0.5) + 1
    if file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end
    return squareName(file, rank)
end

local function pieceType(model)
    local mesh = model:FindFirstChild("Mesh")
    if not mesh then return nil end
    local color = mesh.Color
    local side = color.R > 150 and "White" or "Black"
    local kind = model.Name
    if kind ~= "Pawn" and kind ~= "Knight" and kind ~= "Bishop" and kind ~= "Rook" and kind ~= "Queen" and kind ~= "King" then
        return nil
    end
    return side .. " " .. kind
end

local function scan()
    local result = {}
    local types = {}
    for _, model in ipairs(piecesFolder:GetChildren()) do
        local mesh = model:FindFirstChild("Mesh")
        local square = mesh and positionToSquare(mesh.Position)
        local kind = pieceType(model)
        if square and kind then
            local token = model.Address or model
            result[token] = square
            types[token] = kind
        end
    end
    return result, types
end

local function makeFen(snapshot, types)
    local boardMap = {}
    local codes = {Pawn="p", Knight="n", Bishop="b", Rook="r", Queen="q", King="k"}
    for token, square in pairs(snapshot) do
        local color, kind = types[token]:match("^(%a+) (.+)$")
        local code = codes[kind]
        boardMap[square] = color == "White" and string.upper(code) or code
    end
    local rows = {}
    for rank = 8, 1, -1 do
        local row, empty = "", 0
        for file = 1, 8 do
            local code = boardMap[squareName(file, rank)]
            if code then
                if empty > 0 then row, empty = row .. empty, 0 end
                row = row .. code
            else
                empty = empty + 1
            end
        end
        if empty > 0 then row = row .. empty end
        rows[#rows + 1] = row
    end
    return table.concat(rows, "/") .. " " .. (whiteToMove and "w" or "b") .. " - - 0 1"
end

local function clearArrow()
    for _, arrow in ipairs(arrows) do
        arrow.line:Remove()
        arrow.head:Remove()
    end
    arrows = {}
    arrowFrom, arrowTo = nil, nil
end

local function setArrow(fromSquare, toSquare)
    clearArrow()
    arrowFrom, arrowTo = fromSquare, toSquare
end

RunService.RenderStepped:Connect(function()
    if not arrowFrom or not arrowTo then return end
    local fromSquare, toSquare = arrowFrom, arrowTo
    for _, arrow in ipairs(arrows) do
        arrow.line:Remove()
        arrow.head:Remove()
    end
    arrows = {}
    local function screen(square)
        local file = string.byte(square:sub(1, 1)) - 96
        local rank = tonumber(square:sub(2, 2))
        local part = board:FindFirstChild(tostring(file) .. "," .. tostring(rank))
        if not part then return nil end
        local point, visible = WorldToScreen(part.Position + Vector3.new(0, 1, 0))
        return visible and point or nil
    end
    local fromPoint, toPoint = screen(fromSquare), screen(toSquare)
    if not fromPoint or not toPoint then return end
    local dx, dy = toPoint.X - fromPoint.X, toPoint.Y - fromPoint.Y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1 then return end
    local ux, uy = dx / length, dy / length
    local px, py = -uy, ux
    local line = Drawing.new("Line")
    line.From = fromPoint
    line.To = Vector2.new(toPoint.X - ux * 8, toPoint.Y - uy * 8)
    line.Color = Color3.fromRGB(40, 220, 80)
    line.Thickness = 4
    line.Visible = true
    local head = Drawing.new("Triangle")
    head.PointA = toPoint
    head.PointB = Vector2.new(toPoint.X - ux * 18 + px * 9, toPoint.Y - uy * 18 + py * 9)
    head.PointC = Vector2.new(toPoint.X - ux * 18 - px * 9, toPoint.Y - uy * 18 - py * 9)
    head.Color = Color3.fromRGB(40, 220, 80)
    head.Filled = true
    head.Visible = true
    arrows[1] = {line=line, head=head}
end)

local function recommend(snapshot, types)
    local fen = makeFen(snapshot, types)
    local body = HttpService:JSONEncode({fen = fen, strength = STRENGTH})
    local result
    local lastRaw = ""
    for _ = 1, 2 do
        local posted, raw = pcall(function()
            return httppost(API_URL, body, "application/json", { ["Content-Type"] = "application/json" })
        end)
        lastRaw = posted and raw or tostring(raw)
        local decoded, parsed = pcall(function() return HttpService:JSONDecode(lastRaw) end)
        if decoded and type(parsed) == "table" and parsed.bestmove then
            result = parsed
            break
        end
        task.wait(0.35)
    end
    if not result then
        return false
    end
    local uci = tostring(result.bestmove):match("([a-h][1-8][a-h][1-8][qrbn]?)")
    if not uci then
        return false
    end
    local fromSquare, toSquare = uci:sub(1, 2), uci:sub(3, 4)
    local moving = "Unknown piece"
    for token, square in pairs(snapshot) do
        if square == fromSquare then moving = types[token] or moving break end
    end
    setArrow(fromSquare, toSquare)
    print("[Workspace Chess] Local Stockfish move " .. moving .. ": " .. fromSquare .. " -> " .. toSquare .. " backend=" .. tostring(result.backend))
    return true
end

local function sameSnapshot(a, b)
    for token, square in pairs(a) do
        if b[token] ~= square then return false end
    end
    for token in pairs(b) do
        if not a[token] then return false end
    end
    return true
end

local function movedColor(before, after, types)
    for token, oldSquare in pairs(before) do
        local newSquare = after[token]
        if newSquare and newSquare ~= oldSquare and types[token] then
            return types[token]:sub(1, 5)
        end
    end
    return nil
end

local function usableSnapshot(snapshot, types)
    local count, whiteKing, blackKing = 0, false, false
    for token, square in pairs(snapshot) do
        count = count + 1
        local kind = types[token]
        if kind == "White King" then whiteKing = true end
        if kind == "Black King" then blackKing = true end
    end
    return count >= 4 and whiteKing and blackKing, count
end

local ok, current, types = pcall(scan)
assert(ok, current)
local usable, pieceCount = usableSnapshot(current, types)
while not usable do
    task.wait(0.5)
    local retryOk, retryCurrent, retryTypes = pcall(scan)
    if retryOk then
        current, types = retryCurrent, retryTypes
        usable, pieceCount = usableSnapshot(current, types)
    end
end
previous = current
print("[Workspace Chess] Ready. Play as " .. PLAY_AS)
if PLAY_AS == "White" then recommend(current, types) end

while true do
    task.wait(SCAN_DELAY)
    local success, nextSnapshot, nextTypes = pcall(scan)
    if success then
        if newGameRequested then
            previous = nextSnapshot
            whiteToMove = true
            clearArrow()
            newGameRequested = false
            if PLAY_AS == "White" or PLAY_AS == "Any" then
                recommend(previous, nextTypes)
            end
            continue
        end
        local nextUsable = usableSnapshot(nextSnapshot, nextTypes)
        if not nextUsable then
            clearArrow()
            continue
        end
        local changed = false
        for token, square in pairs(nextSnapshot) do
            if previous[token] ~= square then changed = true break end
        end
        if not changed then
            for token in pairs(previous) do
                if not nextSnapshot[token] then changed = true break end
            end
        end
        if changed then
            clearArrow()
            task.wait(0.35)
            local stable, confirmed = pcall(scan)
            if not stable or not sameSnapshot(nextSnapshot, confirmed) then
                continue
            end
            task.wait(0.2)
            local stableAgain, settled, settledTypes = pcall(scan)
            if not stableAgain or not sameSnapshot(confirmed, settled) then
                continue
            end
            local color = movedColor(previous, settled, types)
            previous = settled
            if color == "White" then
                whiteToMove = false
            elseif color == "Black" then
                whiteToMove = true
            else
                whiteToMove = not whiteToMove
            end
            local yourTurn = PLAY_AS == "Any"
                or (PLAY_AS == "White" and whiteToMove)
                or (PLAY_AS == "Black" and not whiteToMove)
            if yourTurn then
                recommend(settled, settledTypes)
            else
                clearArrow()
            end
        end
    end
end
