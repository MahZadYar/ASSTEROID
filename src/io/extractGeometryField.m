function values = extractGeometryField(S, candidateFields)
values = [];
if isempty(candidateFields) || ~isstruct(S)
    return;
end
for k = 1:numel(candidateFields)
    fn = candidateFields{k};
    if isfield(S, fn)
        data = S.(fn);
        if isnumeric(data) || islogical(data)
            values = double(data(:));
            return;
        end
    end
end
end