%% remove_allData_duplicates
% Script to remove duplicate (p,r) entries from structure-of-arrays allData.mat
% Keeps the first occurrence of each (p,r) pair and removes subsequent duplicates
% across all fields whose first dimension matches the number of entries.

clear; clc;

matFile = 'allData.mat';
if ~isfile(matFile)
    error('File %s not found in current directory.', matFile);
end

S = load(matFile);
if ~isfield(S, 'allData')
    error('Variable "allData" not found in %s.', matFile);
end
allData = S.allData;

assert(isfield(allData,'p') && isfield(allData,'r'), ...
    'allData must contain fields "p" and "r".');

pVals = double(allData.p);
rVals = double(allData.r);

% Ensure column vectors for uniqueness test
pVec = pVals(:);
rVec = rVals(:);
N = numel(pVec);
assert(N == numel(rVec), 'Length mismatch between p and r fields.');

% Determine unique (p,r) pairs and duplicates
key = [pVec, rVec];
[~, uniqueIdx] = unique(key, 'rows', 'stable');
duplicateIdx = setdiff(1:N, uniqueIdx);

if isempty(duplicateIdx)
    fprintf('No duplicate (p,r) pairs detected. Nothing to remove.\n');
    return;
end

fprintf('Detected %d duplicate entries out of %d. Retaining %d unique rows.\n', ...
    numel(duplicateIdx), N, numel(uniqueIdx));

% Build index selection for unique rows
idxKeep = sort(uniqueIdx, 'ascend');

fields = fieldnames(allData);
for k = 1:numel(fields)
    fn = fields{k};
    value = allData.(fn);
    sz = size(value);

    if isempty(value)
        continue;
    end

    if size(value,1) ~= N
        % Leave fields that do not align with entry count untouched
        continue;
    end

    % Prepare subscripts to select rows along first dimension
    subs = repmat({':'}, 1, ndims(value));
    subs{1} = idxKeep;

    % Numeric/logical/string arrays
    if isnumeric(value) || islogical(value) || isstring(value)
        allData.(fn) = value(subs{:});
    elseif iscell(value)
        allData.(fn) = value(subs{:});
    else
        warning('Skipping field %s of unsupported type %s.', fn, class(value));
    end
end

dropped = numel(duplicateIdx);

% Save updated structure back to MAT file
w = whos('allData');
if w.bytes > 2e9
    save(matFile, 'allData', '-v7.3');
else
    save(matFile, 'allData');
end

fprintf('Removed %d duplicate entries and saved updated allData to %s.\n', dropped, matFile);
