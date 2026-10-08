function args = parseNameValuePairs(rawValue)
%parseNameValuePairs Parse name=value pairs from text into cell array.
%   args = parseNameValuePairs(rawValue) parses semicolon- or newline-
%   delimited statements of the form 'name=value' into a cell array
%   suitable for expanding as varargin: {'name1', val1, 'name2', val2, ...}.
%
%   See also: parseScalarValue, parseNumberList

    args = {};
    if isempty(rawValue)
        return;
    end
    if isstring(rawValue) || ischar(rawValue)
        rawValueStr = string(rawValue);
        if rawValueStr == "" || strlength(rawValueStr) == 0
            return;
        end
        tokens = split(rawValueStr, [";", newline]);
        for i = 1:numel(tokens)
            entry = strtrim(tokens(i));
            if entry == ""
                continue;
            end
            parts = split(entry, "=");
            if numel(parts) < 2
                continue;
            end
            name = strtrim(parts(1));
            valueStr = strtrim(strjoin(parts(2:end), "="));
            if name == ""
                continue;
            end
            value = parseScalarValue(valueStr);
            args(end+1:end+2) = {char(name), value}; %#ok<AGROW>
        end
    end
end
