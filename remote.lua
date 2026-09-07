local component = require("component")
local event = require("event")
local serialization = require("serialization")
local term = require("term")
local computer = require("computer")
local unicode = require("unicode")

if not component.isAvailable("modem") or not component.isAvailable("gpu") then
  io.stderr:write("Fehler: Dieses Skript benötigt ein Modem und eine Tier-3 GPU!\n")
  return
end

local modem = component.modem
local gpu = component.gpu
local PORT_REMOTE = 102
modem.open(PORT_REMOTE)
if modem.setStrength then modem.setStrength(400) end

local maxW, maxH = gpu.maxResolution()
local bB, bH = math.min(120, maxW), math.min(35, maxH)
gpu.setResolution(bB, bH)

local CURRENT_TAB = "STARGATE"
local serverAddress = nil

-- Animation & Status
local ringWinkel = 0
local drehRichtung = 1
local letztesChevron = 0
local animFrame = 0
local kawooshFrame = 0
local sgcStatusText = "SGC DIALING SYSTEM READY"

-- RGB Farben (Tier 3)
local C_BG          = 0x05070A
local C_PANEL       = 0x0E121A
local C_BORDER      = 0x1A2332
local C_TEXT        = 0xECF0F1
local C_TEXT_MUTED  = 0x4A5868
local C_GRUEN       = 0x2ECC71
local C_GELB        = 0xF1C40F
local C_ROT         = 0xE74C3C
local C_CYAN        = 0x00E5FF
local C_LILA        = 0x9B59B6
local C_RING_METALL = 0x546E7A
local C_CHEV_OFF    = 0x1C2B38
local C_CHEV_LOCK   = 0xFF9800
local C_CHEV_ON     = 0xFF3D00
local C_KAWOOSH     = 0x00B0FF

-- Original SGC Sternbild-Kurzbezeichnungen
local GLYPH_CODES = {
  [1]  = "EARTH",   [2]  = "CRATER",  [3]  = "VIRGO",   [4]  = "BOOTES",  [5]  = "CENTAUR",
  [6]  = "LIBRA",   [7]  = "SERPENS", [8]  = "SCORPIO", [9]  = "CORONA",  [10] = "LUPUS",
  [11] = "NORMA",   [12] = "OPHIUCH", [13] = "SAGITT",  [14] = "COR.AUS", [15] = "SCUTUM",
  [16] = "CAPRIC",  [17] = "MICROS",  [18] = "SCULPT",  [19] = "PISC.A",  [20] = "AQUAR.",
  [21] = "PEGASUS", [22] = "EQUUL.",  [23] = "ARIES",   [24] = "CETUS",   [25] = "PISCES",
  [26] = "ANDROM",  [27] = "TRIANG",  [28] = "TAURUS",  [29] = "PERSEU",  [30] = "AURIGA",
  [31] = "ERIDAN",  [32] = "ORION",   [33] = "MONOC.",  [34] = "GEMINI",  [35] = "CAN.MAJ",
  [36] = "PUPPIS",  [37] = "CANCER",  [38] = "HYDRA",   [39] = "LYNX"
}

local ACTIVE_DIAL_SEQUENCE = {28, 3, 32, 5, 12, 18, 1}

local ADRESSBUCH = {
  {name = "P3X-982 (ERDE ALPHA)", addr = "SGCBASE", glyphen = "TAURUS / VIRGO / ORION / EARTH"},
  {name = "ABYDOS REBELLEN-AUSSENPOSTEN", addr = "ABYDOSX", glyphen = "CRATER / SERPENS / ARIES / EARTH"},
  {name = "ATLANTIS KONTROLL-RAUM", addr = "ATLANTN", glyphen = "PEGASUS / ANDROMEDA / CETUS / EARTH"}
}

local function drawBox(x, y, w, h, title, titleColor)
  gpu.setBackground(C_PANEL)
  gpu.fill(x, y, w, h, " ")
  gpu.setForeground(C_BORDER)
  gpu.fill(x, y, w, 1, "━")
  gpu.fill(x, y+h-1, w, 1, "━")
  for i=0, h-1 do
    gpu.set(x, y+i, "┃")
    gpu.set(x+w-1, y+i, "┃")
  end
  gpu.set(x, y, "┏")
  gpu.set(x+w-1, y, "┓")
  gpu.set(x, y+h-1, "┗")
  gpu.set(x+w-1, y+h-1, "┛")
  if title then
    gpu.setForeground(titleColor or C_CYAN)
    gpu.set(x+3, y, "┤ " .. title .. " ├")
  end
end

local function drawButton(x, y, w, h, text, bg, fg)
  gpu.setBackground(bg)
  gpu.fill(x, y, w, h, " ")
  gpu.setForeground(fg or C_TEXT)
  local textLen = unicode.len(text)
  gpu.set(x + math.floor((w - textLen)/2), y + math.floor(h/2), text)
end

local function playChevronSound(isFinal)
  pcall(function()
    computer.beep(200, 0.04)
    os.sleep(0.02)
    computer.beep(150, 0.06)
    if isFinal then
      computer.beep(520, 0.25)
    else
      computer.beep(400, 0.12)
    end
  end)
end

local function drawTopChevronLatch(x, y, isLocking, isEngaged, symbolText)
  gpu.setBackground(C_PANEL)
  if isEngaged then
    gpu.setForeground(C_CHEV_ON)
    gpu.set(x+11, y-1, "╒═════════╕")
    gpu.set(x+11, y,   "│ " .. string.format("%-7s", symbolText) .. " │")
    gpu.set(x+11, y+1, "╘═══▼▼▼═══╛")
  elseif isLocking then
    gpu.setForeground(C_CHEV_LOCK)
    gpu.set(x+11, y-1, "╒  ▼▼▼▼  ╕")
    gpu.set(x+11, y,   "│ LOCKED! │")
    gpu.set(x+11, y+1, "╘═════════╛")
  else
    gpu.setForeground(C_CHEV_OFF)
    gpu.set(x+11, y-1, "┌  ┬───┬  ┐")
    gpu.set(x+11, y,   "│ [CHEV 7]│")
    gpu.set(x+11, y+1, "└  ┴───┴  ┘")
  end
end

local function drawSGCGateSystem(x, y, state, chevronsEngaged)
  local activeChevs = tonumber(chevronsEngaged) or 0
  if state == "Connected" then activeChevs = 7 end

  local isLockingNow = false

  if activeChevs > letztesChevron and activeChevs <= 7 then
    letztesChevron = activeChevs
    drehRichtung = (activeChevs % 2 == 0) and 1 or -1
    isLockingNow = true
    
    if activeChevs == 7 or state == "Connected" then
      sgcStatusText = "CHEVRON 7 IS LOCKED!"
      playChevronSound(true)
    else
      sgcStatusText = string.format("CHEVRON %d LOCKED (%s)", activeChevs, GLYPH_CODES[ACTIVE_DIAL_SEQUENCE[activeChevs]] or "SYMBOL")
      playChevronSound(false)
    end
  elseif state == "Idle" or state == "No Gate" then
    letztesChevron = 0
    ringWinkel = 0
    sgcStatusText = "SYSTEM IDLE - WAITING FOR DIAL COMMAND"
  elseif state == "Dialling" then
    ringWinkel = (ringWinkel + (drehRichtung * 3)) % 360
    if not isLockingNow then
      sgcStatusText = string.format("ENCODING CHEVRON %d...", math.min(activeChevs + 1, 7))
    end
  end

  gpu.setBackground(C_PANEL)
  gpu.setForeground(C_RING_METALL)
  gpu.set(x+10, y+1, "⢀⣀⣤⣤⣤⣤⣤⣤⣤⣤⣀⡀")
  gpu.set(x+5,  y+2, "⣠⣾⠿⠉⠉        ⠉⠉⠿⣷⣄")
  gpu.set(x+3,  y+3, "⣵⡿⠁                ⠈⢿⣦")
  gpu.set(x+1,  y+4, "⣾⡿                     ⢿⣷")
  gpu.set(x,    y+5, "⣿⡇                     ⢸⣿")
  gpu.set(x,    y+6, "⣿⡇                     ⢸⣿")
  gpu.set(x,    y+7, "⣿⡇                     ⢸⣿")
  gpu.set(x+1,  y+8, "⢿⣷                     ⣾⡿")
  gpu.set(x+3,  y+9, "⠹⣷⣄                ⣠⣾⠏")
  gpu.set(x+5,  y+10,"⠈⠻⢿⣦⣤⣀        ⣀⣤⣴⠿⠟⠁")
  gpu.set(x+10, y+11,"⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉")

  local topSymbol = (activeChevs >= 7) and (GLYPH_CODES[ACTIVE_DIAL_SEQUENCE[7]] or "EARTH") or "✦"
  drawTopChevronLatch(x, y+1, isLockingNow and activeChevs == 7, activeChevs >= 7, topSymbol)

  local chevPos = {
    [1] = {x=x+25, y=y+3},  [2] = {x=x+27, y=y+6},
    [3] = {x=x+25, y=y+9},  [4] = {x=x+1,  y=y+9},
    [5] = {x=x-1,  y=y+6},  [6] = {x=x+1,  y=y+3}
  }

  for cNr, pos in ipairs(chevPos) do
    if cNr <= activeChevs then
      local symCode = GLYPH_CODES[ACTIVE_DIAL_SEQUENCE[cNr]] or "LOCK"
      gpu.setForeground(C_CHEV_ON)
      gpu.set(pos.x, pos.y, "[" .. symCode .. "]")
    elseif state == "Dialling" and cNr == activeChevs + 1 then
      gpu.setForeground(C_GELB)
      gpu.set(pos.x, pos.y, (animFrame % 2 == 0) and "[SEARCH]" or "[======]")
    else
      gpu.setForeground(C_CHEV_OFF)
      gpu.set(pos.x, pos.y, "[------]")
    end
  end

  if state == "Connected" then
    kawooshFrame = (kawooshFrame + 1) % 3
    gpu.setBackground(C_KAWOOSH)
    gpu.setForeground(0xFFFFFF)
    local wav = (kawooshFrame == 0 and "≈~≈~≈~≈~≈~") or (kawooshFrame == 1 and "~≈~≈~≈~≈~≈") or "▒░▒░▒░▒░▒░"
    gpu.set(x+8, y+5, " " .. wav .. " ")
    gpu.set(x+7, y+6, "  WURMLOCH AKTIV  ")
    gpu.set(x+8, y+7, " " .. wav .. " ")
  end

  gpu.setBackground(C_PANEL)
  gpu.setForeground(C_TEXT_MUTED)
  gpu.set(x+2, y+13, "SGC Passierende Glyphe:")
  local glyphenIndex = (math.floor(ringWinkel / (360 / 39)) % 39) + 1
  gpu.setForeground(C_CYAN)
  gpu.set(x+25, y+13, string.format("[%02d] %s", glyphenIndex, GLYPH_CODES[glyphenIndex] or "UNKNOWN"))
end

local function renderUI(s)
  animFrame = (animFrame + 1) % 4
  local rD = s.lastDaten or {}

  gpu.setBackground(C_BG)
  term.clear()

  gpu.setBackground(C_PANEL)
  gpu.fill(1, 1, 120, 3, " ")
  gpu.setForeground(C_CYAN)
  gpu.set(3, 2, "◈ SGC COMMAND CENTER - COMPUTER DIALING PROGRAM")
  
  drawButton(50, 2, 18, 1, "[ REAKTOR ]", (CURRENT_TAB == "REAKTOR") and C_CYAN or C_BORDER, (CURRENT_TAB == "REAKTOR") and C_BG or C_TEXT)
  drawButton(70, 2, 18, 1, "[ STARGATE DHD ]", (CURRENT_TAB == "STARGATE") and C_LILA or C_BORDER, (CURRENT_TAB == "STARGATE") and C_BG or C_TEXT)

  if CURRENT_TAB == "STARGATE" then
    drawBox(2, 5, 62, 24, "SGC CHEVRON & SYMBOL TELEMETRIE", C_CYAN)
    drawSGCGateSystem(5, 6, s.sgState or "Idle", s.sgChevrons or 0)

    drawBox(38, 7, 23, 5, "SGC LOG", C_GELB)
    gpu.setBackground(C_PANEL)
    gpu.setForeground(C_GELB)
    gpu.set(40, 9, string.sub(sgcStatusText, 1, 19))
    if #sgcStatusText > 19 then
      gpu.set(40, 10, string.sub(sgcStatusText, 20, 38))
    end

    drawButton(38, 14, 23, 2, "IRIS ÖFFNEN", C_GRUEN, C_BG)
    drawButton(38, 17, 23, 2, "IRIS SCHLIESSEN", C_ROT, C_TEXT)
    drawButton(38, 20, 23, 2, "ABBRECHEN", C_BORDER, C_TEXT)

    drawBox(66, 5, 52, 24, "DHD COMPUTER DIALING (SGC)", C_LILA)
    for idx, entry in ipairs(ADRESSBUCH) do
      local yP = 7 + (idx - 1) * 6
      drawBox(68, yP, 48, 5, entry.name, C_CYAN)
      gpu.setBackground(C_PANEL)
      gpu.setForeground(C_TEXT_MUTED)
      gpu.set(70, yP+2, entry.glyphen)
      drawButton(101, yP+1, 13, 3, "WÄHLEN", C_LILA, C_TEXT)
    end

  elseif CURRENT_TAB == "REAKTOR" then
    drawBox(2, 5, 58, 24, "REAKTOR-KERN STATUS", C_GELB)
    gpu.setBackground(C_PANEL)
    gpu.setForeground(C_TEXT)
    gpu.set(5, 8, string.format("Temperatur  : %d °C", tonumber(rD.tempKern) or 0))
    gpu.set(5, 10, string.format("Ausstoß     : %d RF/t", tonumber(rD.rfProTick) or 0))

    drawBox(62, 5, 56, 24, "STEUERUNG & EINSTELLUNGEN", C_CYAN)
    drawButton(65, 8, 22, 3, "▲ STÄBE HEBEN", C_BORDER, C_TEXT)
    drawButton(90, 8, 22, 3, "▼ STÄBE SENKEN", C_BORDER, C_TEXT)
  end

  gpu.setBackground(C_PANEL)
  gpu.fill(1, 30, 120, 5, " ")
  gpu.setForeground(C_BORDER)
  gpu.fill(1, 30, 120, 1, "━")
  gpu.setForeground(C_TEXT)
  gpu.set(3, 32, string.format("Gesamtertrag: %s RF", tostring(s.gesamtRF or 0)))
  drawButton(60, 31, 16, 3, "AUTO", (s.modus == "AUTO") and C_GRUEN or C_BORDER, C_BG)
  drawButton(78, 31, 16, 3, "START", (s.modus == "MANUELL_AN") and C_GRUEN or C_BORDER, C_BG)
  drawButton(96, 31, 16, 3, "STOPP", (s.modus == "MANUELL_AUS") and C_ROT or C_BORDER, C_TEXT)
end

while true do
  modem.broadcast(PORT_REMOTE, serialization.serialize({cmd = "GET_DATA"}))
  local eventTyp, _, sender, port, _, message = event.pullMultiple(0.12, "modem_message", "touch")

  if eventTyp == "modem_message" and port == PORT_REMOTE and message and tostring(message) ~= "" then
    serverAddress = sender
    local success, serverDaten = pcall(serialization.unserialize, tostring(message))
    if success and serverDaten and type(serverDaten) == "table" then
      renderUI(serverDaten)
    end

  elseif eventTyp == "touch" and serverAddress then
    local x, y = tonumber(sender) or 0, tonumber(port) or 0

    if y == 2 then
      if x >= 50 and x <= 68 then
        CURRENT_TAB = "REAKTOR"
      elseif x >= 70 and x <= 88 then
        CURRENT_TAB = "STARGATE"
      end
    end

    if CURRENT_TAB == "STARGATE" then
      if y >= 14 and y <= 15 and x >= 38 and x <= 60 then
        modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="SG_IRIS_OPEN"}))
      elseif y >= 17 and y <= 18 and x >= 38 and x <= 60 then
        modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="SG_IRIS_CLOSE"}))
      elseif y >= 20 and y <= 21 and x >= 38 and x <= 60 then
        modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="SG_DISCONNECT"}))
      elseif x >= 101 and x <= 114 then
        if y >= 8 and y <= 10 then
          modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="SG_DIAL", val=ADRESSBUCH[1].addr}))
        elseif y >= 14 and y <= 16 then
          modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="SG_DIAL", val=ADRESSBUCH[2].addr}))
        elseif y >= 20 and y <= 22 then
          modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="SG_DIAL", val=ADRESSBUCH[3].addr}))
        end
      end
    end

    if CURRENT_TAB == "REAKTOR" then
      if y >= 8 and y <= 10 then
        if x >= 65 and x <= 87 then
          modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="RODS_UP"}))
        elseif x >= 90 and x <= 112 then
          modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="RODS_DOWN"}))
        end
      end
    end

    if y >= 31 and y <= 33 then
      if x >= 60 and x <= 76 then
        modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="SET_MODUS", val="AUTO"}))
      elseif x >= 78 and x <= 94 then
        modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="SET_MODUS", val="MANUELL_AN"}))
      elseif x >= 96 and x <= 112 then
        modem.send(serverAddress, PORT_REMOTE, serialization.serialize({cmd="SET_MODUS", val="MANUELL_AUS"}))
      end
    end
  end
end
