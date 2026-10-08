function vals = parseCellOrString(d, fieldName)
%PARSECELLORSTRING Extract string array from event data field (cell or string).
%   Supports scalar string, string array, cell array of char/string,
%   or char vector. Empty elements and empty strings are filtered out.
%
%   Syntax:
%       vals = parseCellOrString(d, fieldName)

    if ~isstruct(d) || ~isfield(d, fieldName)
        vals = string.empty;
        return;
    end

    raw = d.(fieldName);
    if isstring(raw)
        vals = raw;
    elseif iscell(raw)
        vals = string(raw);
    elseif ischar(raw)
        vals = string(raw);
    else
        vals = string(raw);
    end

    vals = vals(strlength(vals) > 0);
end
