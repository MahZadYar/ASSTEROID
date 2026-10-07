function S = removeRowsFromStruct(S, idx)
if isempty(idx) || ~isstruct(S)
    return;
end
idx = unique(idx(:));
flds = fieldnames(S);
for k = 1:numel(flds)
    fn = flds{k};
    val = S.(fn);
    if isempty(val)
        continue;
    end
    if iscell(val)
        val(idx, :) = [];
    else
        subs = repmat({':'}, 1, ndims(val));
        subs{1} = idx;
        val(subs{:}) = [];
    end
    S.(fn) = val;
end
end