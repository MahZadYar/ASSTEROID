function allData = append_entry_struct(allData, entry)
% append_entry_struct  Append an entry into a structure-of-arrays dataset.
%
% allData = append_entry_struct(allData, entry)
%   Returns an updated structure where numeric/logical fields are stacked
%   along the first dimension with NaN padding as needed, string fields are
%   padded with empty strings, and other types are stored in cell arrays.
%
% This helper mirrors the layout used by save_append to keep consistency
% between in-memory updates and on-disk appends.

if nargin < 1 || isempty(allData)
    allData = struct();
end
if ~isstruct(allData)
    error('allData must be a struct.');
end
if ~isstruct(entry)
    error('entry must be a struct.');
end

if isempty(fieldnames(allData))
    % initialize from entry fields into structure-of-arrays
    flds = fieldnames(entry);
    for k = 1:numel(flds)
        fn = flds{k};
        val = entry.(fn);
        [arr, isNumeric, isString] = to_row_trailing(val);
        if isNumeric
            allData.(fn) = arr; % [1, ...]
        elseif isString
            allData.(fn) = arr; % string array [1, ...]
        else
            allData.(fn) = cell(1, max(1, numel(val)));
            allData.(fn){1,1} = val;
        end
    end
    return;
end

% Append entry to existing structure-of-arrays
fldsExist = fieldnames(allData);
fldsNew = fieldnames(entry);
fldsAll = unique([fldsExist; fldsNew]);

% determine current N as max rows across existing numeric/string fields
N = 0;
for k = 1:numel(fldsExist)
    sz = size(allData.(fldsExist{k}));
    if ~isempty(sz)
        N = max(N, sz(1));
    end
end

% Validate dimensions of overlapping fields to prevent incompatible merges
for k = 1:numel(fldsExist)
    fn = fldsExist{k};
    if ~isfield(entry, fn)
        continue;
    end
    existVal = allData.(fn);
    newVal = entry.(fn);
    if (isnumeric(existVal) || islogical(existVal)) && (isnumeric(newVal) || islogical(newVal))
        existSz = size(existVal);
        [newRow, ~, ~] = to_row_trailing(newVal);
        newSz = size(newRow);
        % Check for excessive dimension mismatch (likely structural incompatibility)
        if numel(existSz) > 2 && numel(newSz) > 2
            trailExist = existSz(2:end);
            trailNew = newSz(2:end);
            maxDiff = max(abs(trailExist - trailNew));
            if maxDiff > 1000
                warning('append_entry_struct:LargeDimMismatch', ...
                    'Field "%s" has large dimension mismatch (existing trailing: [%s], new: [%s]). Structures may be incompatible.', ...
                    fn, num2str(trailExist), num2str(trailNew));
            end
        end
    end
end

for k = 1:numel(fldsAll)
    fn = fldsAll{k};
    hasExist = isfield(allData, fn);
    hasNew = isfield(entry, fn);

    if hasNew
        [rowVal, isNumeric, isString] = to_row_trailing(entry.(fn));
    else
        rowVal = [];
        isNumeric = false;
        isString = false;
    end

    if hasExist
        A = allData.(fn);
        isAString = isa(A, 'string');
        isANumeric = isnumeric(A) || islogical(A);
        isACell = iscell(A);

        if hasNew
            if isANumeric
                if ~isnumeric(rowVal) && ~islogical(rowVal)
                    [rowVal, ~, ~] = to_row_trailing(entry.(fn));
                end
                rowVal = double(rowVal);
                A = double(A);
                
                % Quick check for dimension compatibility
                sizA = size(A, 2:ndims(A));
                sizRow = size(rowVal, 2:ndims(rowVal));
                if ~isequal(sizA, sizRow)
                    % Dimensions differ - need padding
                    A = pad_trailing_to(A, sizRow, NaN);
                    rowVal = pad_trailing_to(rowVal, size(A, 2:ndims(A)), NaN);
                end
                allData.(fn) = cat(1, A, rowVal);
            elseif isAString
                if ~isString
                    rowVal = string(entry.(fn));
                    rowVal = to_row_string(rowVal);
                end
                A = to_string_array(A);
                targ = trailing_dims_max(size(A), size(rowVal));
                A = pad_trailing_to(A, targ, "");
                rowVal = pad_trailing_to(rowVal, targ, "");
                allData.(fn) = cat(1, A, rowVal);
            elseif isACell
                allData.(fn)(N+1,1) = {entry.(fn)}; %#ok<AGROW>
            else
                tmp = num2cell(A);
                tmp(N+1,1) = {entry.(fn)}; %#ok<AGROW>
                allData.(fn) = tmp;
            end
        else
            if isANumeric
                A = double(A);
                padRow = make_pad_row(size(A), NaN);
                allData.(fn) = cat(1, A, padRow);
            elseif isAString
                padRow = make_pad_row(size(A), "");
                allData.(fn) = cat(1, A, padRow);
            elseif isACell
                allData.(fn)(N+1,1) = {[]}; %#ok<AGROW>
            else
                padRow = make_pad_row(size(A), NaN);
                allData.(fn) = cat(1, A, padRow);
            end
        end
    else
        if hasNew
            if isNumeric
                rowVal = double(rowVal);
                targ = size(rowVal, 2:ndims(rowVal));
                A = fill_array([N targ], NaN);
                allData.(fn) = cat(1, A, rowVal);
            elseif isString
                targ = size(rowVal, 2:ndims(rowVal));
                A = strings([N targ]);
                allData.(fn) = cat(1, A, rowVal);
            else
                A = cell(N,1);
                allData.(fn) = [A; {entry.(fn)}];
            end
        end
    end
end
end

function [arr, isNum, isStr] = to_row_trailing(v)
if isnumeric(v) || islogical(v)
    isNum = true;
    isStr = false;
    v = double(v);
    if isvector(v)
        arr = reshape(v, 1, numel(v));
    else
        arr = v;
        if size(arr,1) ~= 1
            arr = reshape(arr, [1, size(arr)]);
        end
    end
elseif isstring(v) || ischar(v)
    isNum = false;
    isStr = true;
    v = string(v);
    if isvector(v)
        arr = reshape(v, 1, numel(v));
    else
        arr = v;
        if size(arr,1) ~= 1
            arr = reshape(arr, [1, size(arr)]);
        end
    end
else
    isNum = false;
    isStr = false;
    arr = v;
end
end

function arr = to_row_string(v)
if isvector(v)
    arr = reshape(v, 1, numel(v));
else
    arr = v;
    if size(arr,1) ~= 1
        arr = reshape(arr, [1, size(arr)]);
    end
end
end

function A = pad_trailing_to(A, targetTrailing, padVal)
cur = size(A);
if numel(cur) < numel(targetTrailing)+1
    cur(numel(cur)+1 : numel(targetTrailing)+1) = 1;
end

% Early exit if dimensions already match
curTrailing = cur(2:end);
if isequal(curTrailing, targetTrailing)
    return;
end

newSz = [cur(1), targetTrailing];

% Safety check: prevent creating arrays larger than reasonable memory limit
maxElements = 1e8; % 100M elements max
if prod(newSz) > maxElements
    error('append_entry_struct:DimensionTooLarge', ...
        'Attempted to create array with %d elements (size: [%s]). This likely indicates incompatible structure dimensions.', ...
        prod(newSz), num2str(newSz));
end

if isstring(A)
    B = strings(newSz);
    B(:) = padVal;
else
    B = repmat(cast(padVal, 'like', double(0)), newSz);
    B = double(B);
end

% Build subscript indices efficiently
if numel(cur) <= 10 && all(cur <= 10000) % reasonable dimensions
    subs = arrayfun(@(d) 1:d, cur, 'UniformOutput', false);
    B(subs{:}) = A;
else
    % For large or many dimensions, use linear indexing fallback
    try
        numElements = prod(cur);
        if numElements > 0 && numElements == numel(A)
            B(1:numElements) = A(:);
        else
            error('Dimension mismatch');
        end
    catch
        error('append_entry_struct:IndexingFailed', ...
            'Failed to pad array with size [%s] to [%s]. Dimensions may be incompatible.', ...
            num2str(cur), num2str(newSz));
    end
end
A = B;
end

function dims = trailing_dims_max(szA, szB)
len = max(numel(szA), numel(szB));
szA(end+1:len) = 1;
szB(end+1:len) = 1;
dims = max(szA(2:end), szB(2:end));
end

function padRow = make_pad_row(szA, padVal)
trailing = szA(2:end);
if isstring(padVal)
    padRow = strings([1 trailing]);
    padRow(:) = padVal;
    return;
end
padRow = double(padVal) * ones([1 trailing]);
end

function A = fill_array(sz, padVal)
A = double(padVal) * ones(sz);
end

function S = to_string_array(A)
if isstring(A)
    S = A;
    return;
end
S = string(A);
end
