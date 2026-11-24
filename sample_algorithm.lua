-- Sample Lua Program: Math and String Algorithms
local function is_prime(num)
    if num <= 1 then
        return false
    end
    local d = 2
    while d * d <= num do
        if num % d == 0 then
            return false
        end
        d = d + 1
    end
    return true
end

local function fibonacci(n)
    local a, b = 0, 1
    local count = 0
    while count < n do
        local temp = a + b
        a = b
        b = temp
        count = count + 1
    end
    return a
end

local function reverse_count(limit)
    local val = limit
    repeat
        val = val - 1
    until val <= 0
    return val
end

local total = 0
for idx = 1, 5 do
    total = total + idx * idx
end

local primes_found = 0
for x = 1, 20 do
    if is_prime(x) then
        primes_found = primes_found + 1
    end
end

local user_role = "admin"
local access_level = 0
if user_role == "guest" then
    access_level = 1
elseif user_role == "member" then
    access_level = 2
elseif user_role == "admin" then
    access_level = 99
else
    access_level = -1
end

print("=== Algorithm Test Results ===")
print("Fibonacci(10):", fibonacci(10))
print("Primes under 20:", primes_found)
print("Reverse count:", reverse_count(3))
print("Sum of squares 1..5:", total)
print("Access level:", access_level)
