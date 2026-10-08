function values = parseNumberList(rawValue, defaultValue)
%parseNumberList Parse comma-, semicolon-, or whitespace-delimited numbers.
%   values = parseNumberList(rawValue, defaultValue)
%
%   Examples:
%       parseNumberList("128, 256, 512") -> [128, 256, 512]
%       parseNumberList("", [128])       -> [128]
%
%   See also: parseNameValuePairs, parseScalarValue

    if nargin < 2
        defaultValue = [];
    end
    if isstring(rawValue)
        rawValue = char(rawValue);
    end
    if isempty(rawValue)
        values = defaultValue;
        return;
    end
    if isnumeric(rawValue)
        values = double(rawValue(:)');
        return;
    end
    tokens = regexp(rawValue, '[,;\s]+', 'split');
    tokens = tokens(~cellfun('isempty', tokens));
    if isempty(tokens)
        values = defaultValue;
        return;
    end
    values = str2double(tokens);
    values = values(isfinite(values));
    if isempty(values)
        values = defaultValue;
        return;
    end
    values = double(values(:)');
end
