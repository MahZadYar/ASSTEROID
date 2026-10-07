function data = getColumn(allData, pattern, options)
% getColumn  Extract a column/field from struct or table by field name pattern.
%
% data = getColumn(allData, pattern) extracts data from a structure-of-arrays
% (SoA) or table by matching the field/variable name against pattern.
% Returns NaN-filled column if field is not found.
%
% Parameters:
%   FillValue - Value to use when field not found (default: NaN)

arguments
    allData {mustBeA(allData, ["struct", "table"])}
    pattern (1,1) string
    options.FillValue = NaN
end

% Handle struct (SoA format)
if isstruct(allData)
    fieldNames = string(fieldnames(allData));
    idx = findVarName(fieldNames, pattern);
    
    if isempty(idx)
        warning('getColumn:MissingField', ...
            'Field matching pattern "%s" not found. Filling with default value.', pattern);
        % Determine number of rows from first field
        flds = fieldnames(allData);
        if isempty(flds)
            data = options.FillValue;
            return;
        end
        firstField = allData.(flds{1});
        nRows = size(firstField, 1);
        data = repmat(options.FillValue, nRows, 1);
        return;
    end
    
    data = allData.(fieldNames(idx));
    if ~isnumeric(data) && ~islogical(data)
        data = double(data);
    end
    return;
end

% Handle table format
if istable(allData)
    varNames = string(allData.Properties.VariableNames);
    idx = findVarName(varNames, pattern);
    
    if isempty(idx)
        warning('getColumn:MissingColumn', ...
            'Column matching pattern "%s" not found. Filling with default value.', pattern);
        data = repmat(options.FillValue, height(allData), 1);
        return;
    end
    
    data = allData{:, idx};
    if ~isnumeric(data) && ~islogical(data)
        data = double(data);
    end
    return;
end
end