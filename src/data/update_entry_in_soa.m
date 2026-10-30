function allData = update_entry_in_soa(allData, rowIdx, entry)
% update_entry_in_soa Update an existing row in a Structure-of-Arrays (SoA) struct.
%
%   allData = update_entry_in_soa(allData, rowIdx, entry) updates rowIdx in-place
%   with fields from entry. Handles:
%     1. Dynamic addition of new fields (fills existing rows with NaNs / empty strings).
%     2. Expansion of column dimensions for 2D spectral fields (pads existing rows with NaNs).
%     3. Preservation of all other rows and untouched fields.
%
%   Inputs:
%       allData - Structure-of-Arrays (SoA) struct
%       rowIdx  - Scalar integer row index to update (1 <= rowIdx <= N)
%       entry   - Struct representing a single row/geometry
%
%   Output:
%       allData - Updated SoA struct
%
%   See also: append_entry_struct, extractEntryStruct, removeRowsFromStruct

    if nargin < 3
        error("update_entry_in_soa:NotEnoughInputs", "Requires allData, rowIdx, and entry.");
    end
    if isempty(allData) || ~isstruct(allData)
        error("update_entry_in_soa:InvalidAllData", "allData must be a non-empty struct.");
    end
    if ~isstruct(entry)
        error("update_entry_in_soa:InvalidEntry", "entry must be a struct.");
    end

    N = structRowCount(allData);
    if rowIdx < 1 || rowIdx > N
        error("update_entry_in_soa:IndexOutOfBounds", ...
            "rowIdx (%d) must be between 1 and %d.", rowIdx, N);
    end

    fldsEntry = fieldnames(entry);

    %% 1. Initialize any fields present in entry that do not yet exist in allData
    for k = 1:numel(fldsEntry)
        fn = fldsEntry{k};
        if ~isfield(allData, fn)
            val = entry.(fn);
            if isnumeric(val) || islogical(val)
                val = double(val);
                if isscalar(val)
                    allData.(fn) = nan(N, 1);
                else
                    nCols = max(1, numel(val));
                    allData.(fn) = nan(N, nCols);
                end
            elseif isstring(val)
                if isscalar(val)
                    allData.(fn) = strings(N, 1);
                else
                    allData.(fn) = strings(N, max(1, numel(val)));
                end
            elseif iscell(val)
                allData.(fn) = cell(N, max(1, numel(val)));
            else
                allData.(fn) = cell(N, 1);
            end
        end
    end

    %% 2. For any 2D spectral array where entry has MORE columns than allData,
    %     pad all existing rows in allData to match the new column length
    for k = 1:numel(fldsEntry)
        fn = fldsEntry{k};
        val = entry.(fn);
        if (isnumeric(val) || islogical(val)) && ~isscalar(val) && isvector(val)
            val = double(val(:)');
            entry.(fn) = val;
            curRows = size(allData.(fn), 1);
            curCols = size(allData.(fn), 2);
            newCols = numel(val);
            if newCols > curCols
                padCols = newCols - curCols;
                if curRows == N
                    allData.(fn) = [allData.(fn), nan(N, padCols)];
                elseif curRows == 1
                    allData.(fn) = [allData.(fn), nan(1, padCols)];
                end
            end
        elseif isstring(val) && ~isscalar(val) && isvector(val)
            curRows = size(allData.(fn), 1);
            curCols = size(allData.(fn), 2);
            newCols = numel(val);
            if newCols > curCols
                padCols = newCols - curCols;
                if curRows == N
                    allData.(fn) = [allData.(fn), strings(N, padCols)];
                elseif curRows == 1
                    allData.(fn) = [allData.(fn), strings(1, padCols)];
                end
            end
        end
    end

    %% 3. Write entry fields into rowIdx
    fldsAll = fieldnames(allData);
    for k = 1:numel(fldsAll)
        fn = fldsAll{k};
        if isfield(entry, fn)
            val = entry.(fn);
            curRows = size(allData.(fn), 1);
            if curRows == N
                if isnumeric(val) || islogical(val)
                    val = double(val);
                    if isscalar(val)
                        allData.(fn)(rowIdx, 1) = val;
                    else
                        valRow = val(:)';
                        curCols = size(allData.(fn), 2);
                        if numel(valRow) < curCols
                            valRow(end+1:curCols) = NaN;
                        end
                        allData.(fn)(rowIdx, 1:curCols) = valRow(1:curCols);
                    end
                elseif isstring(val)
                    if isscalar(val)
                        allData.(fn)(rowIdx, 1) = string(val);
                    else
                        valRow = string(val(:)');
                        curCols = size(allData.(fn), 2);
                        if numel(valRow) < curCols
                            valRow(end+1:curCols) = "";
                        end
                        allData.(fn)(rowIdx, 1:curCols) = valRow(1:curCols);
                    end
                elseif iscell(val)
                    allData.(fn)(rowIdx, 1:numel(val)) = val;
                end
            elseif curRows == 1 && isscalar(val)
                % Branch/dataset level metadata or broadcasted scalar
                if isnumeric(val) || islogical(val)
                    allData.(fn) = double(val);
                elseif isstring(val)
                    allData.(fn) = string(val);
                end
            end
        end
    end
end
