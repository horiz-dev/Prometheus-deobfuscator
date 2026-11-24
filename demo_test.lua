-- Prometheus Test Program
local secret_key = "MY_SUPER_SECRET_KEY_12345"
local app_title = "Prometheus Deobfuscator Demo"

local function compute_factorial(n)
    local result = 1
    local i = 1
    while i <= n do
        result = result * i
        i = i + 1
    end
    return result
end

local function countdown(start_val)
    local count = start_val
    repeat
        count = count - 1
    until count <= 0
    return count
end

local sum = 0
for k = 1, 10 do
    sum = sum + k
end

local mode = 2
local status = "unknown"
if mode == 1 then
    status = "Mode 1 active"
elseif mode == 2 then
    status = "Mode 2 active"
else
    status = "Fallback mode"
end

print(app_title)
print("Secret:", secret_key)
print("Factorial of 5:", compute_factorial(5))
print("Countdown finished at:", countdown(5))
print("Sum 1..10:", sum)
print("Status:", status)
