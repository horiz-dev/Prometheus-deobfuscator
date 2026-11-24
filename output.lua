local var_1, var_2, var_3, var_4, var_5, var_6;
var_1 = function(var_9)
		local var_10, var_11, var_12, var_13, var_14;
		var_10, var_11 = 1, 1;
		while var_10 <= var_9 do
			var_11 = var_11 * var_10;
			var_13 = 1;
			var_10 = var_10 + var_13;
		end;
		return var_11;
	end;
var_2 = 1;
var_3 = function(var_15)
		local var_16, var_17, var_18, var_19;
		var_16 = var_15;
		repeat
			var_17 = 1;
			var_16 = var_16 - var_17;
			var_17 = 0;
		until var_16 <= var_17;
		return var_16;
	end;
var_4 = 0;
for r = 1, 10, 1 do
	var_4 = var_4 + r;
end;
var_5, var_2, var_6 = "unknown", 2, 1;
if var_2 == 1 then
	var_5 = "Mode 1 active";
elseif var_2 == 2 then
	var_5 = "Mode 2 active";
else
	var_5 = "Fallback mode";
end;
print("Prometheus Deobfuscator Demo");
print("Secret:", "MY_SUPER_SECRET_KEY_12345");
print("Factorial of 5:", var_1(5));
print("Countdown finished at:", var_3(5));
print("Sum 1..10:", var_4);
print("Status:", var_5);