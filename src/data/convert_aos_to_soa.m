% convert_aos_to_soa
% Convert an existing array-of-struct 'allData' in a .mat file into a
% structure-of-arrays (SoA) form suitable for indexing like allData.a(i)
% and allData.lambda(i,j).
%
% How it works
% - Loads variable 'allData' from an input .mat (AoS style: allData(i).field)
% - Builds a new struct where each field is an array with first dim = entries
%   * Numeric/logical -> double arrays; vectors become rows [N x L]
%   * String/char     -> string arrays; rows [N x L]
%   * Other types     -> cell arrays [N x 1]
% - Fields are padded along trailing dims to the largest size across entries
%   (NaN for numerics, "" for strings, [] for cells).
% - Saves to an output .mat as variable 'allData' (SoA)

%% Config (you may set these before running)
inputFile = 'allData - Backup.mat';
outputFile = 'allData_soa.mat';

%% Select files if not set
if isempty(inputFile)
    [f, p] = uigetfile('*.mat', 'Select MAT-file containing AoS allData');
    if isequal(f,0), error('Canceled.'); end
    inputFile = fullfile(p,f);
end
if isempty(outputFile)
    [pth, base, ~] = fileparts(inputFile);
    outputFile = fullfile(pth, base + "_soa.mat");
end

%% Load AoS
if ~isfile(inputFile)
    error('Input file not found: %s', inputFile);
end
S = load(inputFile, 'allData');
if ~isfield(S, 'allData')
    error('Variable ''allData'' not found in %s', inputFile);
end
AoS = S.allData;
if ~isstruct(AoS)
    error('allData is not a struct in %s', inputFile);
end
N = numel(AoS);
if N == 0
    error('allData is empty.');
end

%% Gather field list (assumes consistent fields; will still handle missing)
flds = fieldnames(AoS);

%% Build SoA
SoA = struct();
for k = 1:numel(flds)
    fn = flds{k};
    % collect values
    vals = cell(N,1);
    for i = 1:N
        if isfield(AoS(i), fn)
            vals{i} = AoS(i).(fn);
        else
            vals{i} = []; % missing
        end
    end

    % Decide storage class by first non-empty
    idx = find(~cellfun(@isempty, vals), 1);
    if isempty(idx)
        % all empty -> numeric NaN vector row
        SoA.(fn) = nan(N,1);
        continue;
    end
    v1 = vals{idx};

    if isnumeric(v1) || islogical(v1)
        % numeric: convert to double row-first
        rows = cellfun(@(v) to_row_trailing_numeric(v), vals, 'UniformOutput', false);
        % find max trailing dims
        targ = [0 0]; % placeholder; compute properly below
        maxDims = 1; % number of dims including row
        for i = 1:N
            A = rows{i};
            if isempty(A), A = nan(1,0); end
            sz = size(A);
            maxDims = max(maxDims, numel(sz));
        end
        % get target trailing sizes
        targTrailing = zeros(1, maxDims-1);
        for i = 1:N
            A = rows{i};
            if isempty(A), A = nan(1,0); end
            sz = size(A);
            sz(end+1:maxDims) = 1;
            targTrailing = max(targTrailing, sz(2:end));
        end
        % prealloc and fill
        out = nan([N targTrailing]);
        for i = 1:N
            A = rows{i};
            if isempty(A)
                continue;
            end
            A = pad_trailing_to_numeric(A, targTrailing, NaN);
            % build subs
            subs = repmat({':'}, 1, numel(targTrailing));
            out(i, subs{:}) = A;
        end
        SoA.(fn) = out;

    elseif isstring(v1) || ischar(v1)
        % strings: convert to row string array
        rows = cellfun(@(v) to_row_trailing_string(v), vals, 'UniformOutput', false);
        % target trailing dims
        maxDims = 1;
        for i = 1:N
            A = rows{i}; sz = size(A); maxDims = max(maxDims, numel(sz));
        end
        targTrailing = zeros(1, maxDims-1);
        for i = 1:N
            A = rows{i}; sz = size(A); sz(end+1:maxDims) = 1; targTrailing = max(targTrailing, sz(2:end));
        end
        out = strings([N targTrailing]);
        out(:) = "";
        for i = 1:N
            A = rows{i};
            if isempty(A)
                continue;
            end
            A = pad_trailing_to_string(A, targTrailing, "");
            subs = repmat({':'}, 1, numel(targTrailing));
            out(i, subs{:}) = A;
        end
        SoA.(fn) = out;

    else
        % other types -> cell column
        C = cell(N,1);
        for i = 1:N, C{i,1} = vals{i}; end
        SoA.(fn) = C;
    end
end

%% Save SoA
allData = SoA; %#ok<NASGU>
% decide v7.3
w = whos('allData'); useV73 = ~isempty(w) && w.bytes > 2e9;
if useV73
    save(outputFile, 'allData', '-v7.3');
else
    save(outputFile, 'allData');
end
fprintf('Saved structure-of-arrays to: %s\n', outputFile);

%% Local helpers
function A = to_row_trailing_numeric(v)
    if isempty(v)
        A = [];
        return;
    end
    v = double(v);
    if isvector(v)
        A = reshape(v, 1, numel(v));
    else
        A = v;
        if size(A,1) ~= 1
            A = reshape(A, [1, size(A)]);
        end
    end
end

function A = to_row_trailing_string(v)
    if isempty(v)
        A = strings(0,1);
        return;
    end
    A = string(v);
    if isvector(A)
        A = reshape(A, 1, numel(A));
    else
        if size(A,1) ~= 1
            A = reshape(A, [1, size(A)]);
        end
    end
end

function A = pad_trailing_to_numeric(A, targTrailing, padVal)
    cur = size(A);
    if numel(cur) < numel(targTrailing)+1
        cur(numel(cur)+1: numel(targTrailing)+1) = 1;
    end
    newSz = [1, targTrailing];
    B = double(padVal) * ones(newSz);
    subs = arrayfun(@(d) 1:d, cur, 'UniformOutput', false);
    B(subs{:}) = A;
    A = B;
end

function A = pad_trailing_to_string(A, targTrailing, padVal)
    cur = size(A);
    if numel(cur) < numel(targTrailing)+1
        cur(numel(cur)+1: numel(targTrailing)+1) = 1;
    end
    newSz = [1, targTrailing];
    B = strings(newSz); B(:) = padVal;
    subs = arrayfun(@(d) 1:d, cur, 'UniformOutput', false);
    B(subs{:}) = A;
    A = B;
end
