function names = sanitiseMetricList(raw)
% SANITISEMETRICLIST Flatten and filter cell/string metric arrays into row vector.
%
%   names = sanitiseMetricList(raw) takes raw metrics specified as a cell array,
%   nested cell array, or string array, filters out empty and missing entries,
%   and returns a clean 1-by-M string row vector.
%
%   See also: STRING, STRTRIM

    if isempty(raw), names = string.empty(1, 0); return; end
    if iscell(raw)
        while isscalar(raw) && iscell(raw{1})
            raw = raw{1};
        end
    end
    names = string(raw);
    names = names(~ismissing(names) & strlength(strtrim(names)) > 0);
    names = reshape(names, 1, []);
end
