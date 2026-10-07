function db = importDatabaseFromHDF5(h5File)
% importDatabaseFromHDF5  Import unified SERS database from HDF5 format.
%
%   db = importDatabaseFromHDF5(h5File)
%
%   Deserializes a native HDF5 file into the hierarchical database struct.
%   - HDF5 Groups become struct branches.
%   - HDF5 Datasets become numeric arrays.
%   - Group Attributes become scalars, small vectors, and strings.
%
%   Input:
%       h5File - string, path to input .h5 file
%
%   Output:
%       db     - Unified database struct
%
%   Example:
%       db = importDatabaseFromHDF5("sers_database.h5");
%
%   See also: exportDatabaseToHDF5, createDatabaseStruct

    arguments
        h5File (1,1) string
    end

    if ~isfile(h5File)
        error('importDatabaseFromHDF5:FileNotFound', 'File not found: %s', h5File);
    end

    % Get file info
    info = h5info(char(h5File));
    
    % Initialize empty struct
    db = struct();
    
    % Walk the HDF5 hierarchy
    db = walkH5Group(info, db, h5File);
end

function s = walkH5Group(groupInfo, s, h5File)
    % 1. Read Attributes (scalars, strings, small vectors)
    for i = 1:numel(groupInfo.Attributes)
        attr = groupInfo.Attributes(i);
        name = attr.Name;
        val = attr.Value;
        
        % Convert HDF5 strings to MATLAB strings
        if ischar(val) || iscellstr(val)
            val = string(val);
        end
        
        s.(name) = val;
    end
    
    % 2. Read Datasets (numeric arrays)
    for i = 1:numel(groupInfo.Datasets)
        ds = groupInfo.Datasets(i);
        name = ds.Name;
        
        % Construct full path
        if strcmp(groupInfo.Name, '/')
            path = "/" + name;
        else
            path = groupInfo.Name + "/" + name;
        end
        
        % Read dataset
        try
            val = h5read(char(h5File), char(path));
            
            % Convert HDF5 strings to MATLAB strings
            if ischar(val) || iscellstr(val)
                val = string(val);
            end
            
            s.(name) = val;
        catch ME
            warning('Failed to read dataset %s: %s', path, ME.message);
        end
    end
    
    % 3. Recurse into Subgroups
    for i = 1:numel(groupInfo.Groups)
        subgroup = groupInfo.Groups(i);
        
        % Extract group name from path (e.g., "/Sim" -> "Sim")
        parts = strsplit(subgroup.Name, '/');
        name = parts{end};
        
        % Initialize subgroup struct
        s.(name) = struct();
        
        % Recurse
        s.(name) = walkH5Group(subgroup, s.(name), h5File);
    end
end
