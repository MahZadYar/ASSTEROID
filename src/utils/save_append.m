function save_append(entry, folder, filename)
% save_append  Append an entry into allData as a structure-of-arrays.
%
% This stores each field as an array stacked along the first dimension:
%   - Numeric/logical fields -> stored as double arrays with size [N, ...]
%     where N is number of appended entries. Vectors are stored as rows, so
%     allData.lambda(i,j) indexing is supported.
%   - String/char fields -> stored as string arrays stacked along dim 1.
%   - Other types -> stored as cell arrays stacked along dim 1 (each row a cell).
%
% Usage:
%   save_append(entry, filename)
%   save_append(entry, folder, filename)
% If 'folder' is provided it will be used as the directory for the file.
%
% The file contains variable 'allData' in structure-of-arrays layout.

if nargin < 2
    error('Usage: save_append(entry, filename) or save_append(entry, folder, filename)');
end
if nargin == 2
    filename = folder; folder = '';
end

if ~ischar(filename) && ~isstring(filename)
    error('filename must be a string or char vector');
end
if ~isempty(folder) && ~(ischar(folder) || isstring(folder))
    error('folder must be a string or char vector');
end

filename = char(filename);
if ~isempty(folder)
    filename = fullfile(char(folder), filename);
end

% ensure directory exists
[pth, ~, ~] = fileparts(filename);
if ~isempty(pth) && ~isfolder(pth)
    mkdir(pth);
end

% load existing
hasFile = isfile(filename);
if hasFile
    S = load(filename);
else
    S = struct();
end

if isfield(S, 'allData') && isstruct(S.allData)
    allData = S.allData;
else
    allData = struct();
end

allData = append_entry_struct(allData, entry);

% decide v7.3
w = whos('allData'); useV73 = ~isempty(w) && w.bytes > 2e9;
if hasFile
    if useV73
        save(filename, 'allData', '-append', '-v7.3');
    else
        save(filename, 'allData', '-append');
    end
else
    if useV73
        save(filename, 'allData', '-v7.3');
    else
        save(filename, 'allData');
    end
end
end
