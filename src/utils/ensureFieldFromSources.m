function S = ensureFieldFromSources(S, targetField, sourceFields)
if isempty(sourceFields) || ~isstruct(S)
    return;
end
if isfield(S, targetField)
    targetVals = S.(targetField);
else
    targetVals = [];
end
for k = 1:numel(sourceFields)
    srcName = sourceFields{k};
    if ~isfield(S, srcName)
        continue;
    end
    srcVals = S.(srcName);
    if isempty(targetVals)
        S.(targetField) = srcVals;
        targetVals = S.(targetField);
    else
        if isnumeric(targetVals) && isnumeric(srcVals) && isequal(size(targetVals), size(srcVals))
            mask = isnan(targetVals) & ~isnan(srcVals);
            if any(mask, 'all')
                targetVals(mask) = srcVals(mask);
                S.(targetField) = targetVals;
            end
        end
    end
end
end