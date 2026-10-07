function entry = extractEntryStruct(S, idx)
% extractEntryStruct  Return a single-row struct for row idx from SoA dataset.

entry = struct();
if isempty(S) || ~isstruct(S)
    return;
end
flds = fieldnames(S);
for k = 1:numel(flds)
    fn = flds{k};
    val = S.(fn);
    
    % Skip scalar branch parameters or broadcasted arrays (like [1 x L] lambda)
    if size(val, 1) == 1
        entry.(fn) = val;
        continue;
    end
    
    if isnumeric(val) || islogical(val) || isstring(val)
        subs = repmat({':'}, 1, ndims(val));
        subs{1} = idx;
        slice = val(subs{:});
        entry.(fn) = slice;
    elseif iscell(val)
        entry.(fn) = val(idx, :);
    else
        subs = repmat({':'}, 1, ndims(val));
        subs{1} = idx;
        entry.(fn) = val(subs{:});
    end
end
end