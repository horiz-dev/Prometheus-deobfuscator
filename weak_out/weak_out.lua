local status_2, mode_2, status, var_3, mode;
local function compute_factorial(...)
	local result, i, var_6;
	local var_7 = { ... };
	result = 1;
	i, var_6 = 1, var_7[1];
	if i <= var_6 then
		result = result * i;
		i = i + 1;
		while i <= var_6 do
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
mode_2 = 1 - 1;
mode, mode_2 = not var_3, 1 + mode_2;
status = 10 >= mode_2;
status = mode and status;
mode = 10 <= mode_2;
mode = var_3 and mode;
if mode or status then
	status = mode_2;
	mode = status_2 + status;
	status_2 = status_2 + status;
	mode, mode_2 = not var_3, 1 + mode_2;
	status = 10 >= mode_2;
	status = mode and status;
	mode = 10 <= mode_2;
	mode = var_3 and mode;
	while mode or status do
		status = mode_2;
		status_2 = status_2 + status;
		mode, mode_2 = not var_3, 1 + mode_2;
		status = 10 >= mode_2;
		status = mode and status;
		mode = 10 <= mode_2;
		mode = var_3 and mode;
	end;
else
 
end;
status = "unknown";
mode_2 = 2;
if mode_2 == 1 then
	status = "Mode 1 active";
else
	if mode_2 == 2 then
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