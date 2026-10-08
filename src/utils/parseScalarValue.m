function value = parseScalarValue(valueStr)
%parseScalarValue Parse string representation of a scalar into MATLAB type.
%   value = parseScalarValue(valueStr) converts strings like "true", "false",
%   "inf", "nan", numeric strings, comma-separated lists, and quoted strings
%   into their appropriate MATLAB representations.
%
%   See also: parseNameValuePairs, parseNumberList

    valueStr = string(valueStr);
    if valueStr == ""
        value = "";
        return;
    end
    lowerVal = lower(valueStr);
    if lowerVal == "true"
        value = true;
        return;
    elseif lowerVal == "false"
        value = false;
        return;
    elseif lowerVal == "inf"
        value = inf;
        return;
    elseif lowerVal == "nan"
        value = NaN;
        return;
    end

    if startsWith(valueStr, """") && endsWith(valueStr, """")
        value = extractBetween(valueStr, 2, strlength(valueStr) - 1);
        value = string(value);
        return;
    elseif startsWith(valueStr, "'") && endsWith(valueStr, "'")
        value = extractBetween(valueStr, 2, strlength(valueStr) - 1);
        value = string(value);
        return;
    end

    if contains(valueStr, ",")
        parts = split(valueStr, ",");
        nums = str2double(strtrim(parts));
        if all(isfinite(nums))
            value = nums';
            return;
        end
    end

    numericValue = str2double(valueStr);
    if isfinite(numericValue)
        value = numericValue;
    else
        value = char(valueStr);
    end
end
