local status_3, status_2, status, var_3, mode;
local function compute_factorial(n)
	local i, result = 1, 1;
	if i <= n then
		result = result * i;
		i = i + 1;
		while i <= n do
			result = result * i;
			i = i + 1;
		end;
	else
 
	end;
	return result;
end;
local function countdown(start_val)
	repeat
		start_val = start_val - 1;
	until start_val <= 0;
	return start_val;
end;
status_2 = 0;
var_3 = 0 > 1;
status_3 = 1 - 1;
status_3, mode = status_3 + 1, not var_3;
status = 10 >= status_3;
status = mode and status;
mode = 10 <= status_3;
mode = var_3 and mode;
if mode or status then
	status = status_3;
	mode = status_2 + status;
	status_2 = status_2 + status;
	status_3, mode = status_3 + 1, not var_3;
	status = 10 >= status_3;
	status = mode and status;
	mode = 10 <= status_3;
	mode = var_3 and mode;
	while mode or status do
		status = status_3;
		status_2 = status_2 + status;
		status_3, mode = status_3 + 1, not var_3;
		status = 10 >= status_3;
		status = mode and status;
		mode = 10 <= status_3;
		mode = var_3 and mode;
	end;
else
 
end;
status, status_3 = "unknown", 2;
if status_3 == 1 then
	status = "Mode 1 active";
else
	if status_3 == 2 then
		status = "Mode 2 active";
	else
		status = "Fallback mode";
	end;
end;
print("Prometheus Deobfuscator Demo");
print("Secret:", "MY_SUPER_SECRET_KEY_12345");
print("Factorial of 5:", compute_factorial(5));
print("Countdown finished at:", countdown(5));
print("Sum 1..10:", status_2);
print("Status:", status);