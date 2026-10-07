function N = structRowCount(S)
% structRowCount  Number of geometry rows in a SoA or database-branch struct.
%
%   Returns the maximum first-dimension size across all numeric/logical fields.
%   String and cell metadata fields (e.g., Source, Parent added by populateBranch)
%   are skipped so that db.Sim branches with prepended metadata are handled
%   identically to plain SoA structs.
N = 0;
if isempty(S) || ~isstruct(S)
    return;
end
flds = fieldnames(S);
for k = 1:numel(flds)
    val = S.(flds{k});
    if isempty(val) || ~(isnumeric(val) || islogical(val))
        continue;  % skip strings, cell arrays, nested structs, etc.
    end
    N = max(N, size(val, 1));
end
end