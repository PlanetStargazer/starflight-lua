-- Build a Forth thread from a token list, for forced tests.
--   123 / -5 / $1F   literal         NAME   word from the dictionary (main, or a unique overlay word)
--   @E8F3            raw parameter-field address of a word
local T = {}
local names = require("names1")
local ovn = require("names1ov")
local byname = {}
for pfa, n in pairs(names) do if not byname[n] then byname[n] = pfa end end
local ovbyname = {}
for pfa, list in pairs(ovn) do
    for entry in list:gmatch("[^|]+") do
        local n = entry:match("^(.*)@%d+$") or entry
        ovbyname[n] = ovbyname[n] or {}
        ovbyname[n][#ovbyname[n] + 1] = pfa
    end
end
local LIT, GO = 0x175D, 0x16A1
T.START = 0x40

-- CFA (code-field address) of a dictionary word, by name
function T.cfa(name)
    local pfa = byname[name]
    if not pfa and ovbyname[name] then
        if #ovbyname[name] > 1 then error("ambiguous overlay word " .. name) end
        pfa = ovbyname[name][1]
    end
    if not pfa then error("unknown word " .. name) end
    return pfa - 2
end

function T.cells(tokens)
    local cells = {}
    for tok in tokens:gmatch("%S+") do
        local n
        if tok:match("^%-?%d+$") then n = tonumber(tok)
        elseif tok:match("^%$%x+$") then n = tonumber(tok:sub(2), 16) end
        if n then
            cells[#cells + 1] = LIT; cells[#cells + 1] = n % 65536
        elseif tok:match("^@%x+$") then
            cells[#cells + 1] = tonumber(tok:sub(2), 16) - 2
        else
            local pfa = byname[tok]
            if not pfa and ovbyname[tok] then
                if #ovbyname[tok] > 1 then error("ambiguous overlay word " .. tok) end
                pfa = ovbyname[tok][1]
            end
            if not pfa then error("unknown word " .. tok) end
            cells[#cells + 1] = pfa - 2
        end
    end
    cells[#cells + 1] = LIT; cells[#cells + 1] = 0; cells[#cells + 1] = GO
    return cells
end

function T.install(wr16, tokens)
    local cells = T.cells(tokens)
    for i, c in ipairs(cells) do wr16(T.START + (i - 1) * 2, c) end
    return T.START
end
return T
