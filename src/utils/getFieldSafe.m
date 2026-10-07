function data = getFieldSafe(entry, fieldName)
if isstruct(entry) && isfield(entry, fieldName)
    data = entry.(fieldName);
else
    data = [];
end
end