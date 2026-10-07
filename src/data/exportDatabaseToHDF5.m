function exportDatabaseToHDF5(db, h5File)
% exportDatabaseToHDF5  Export unified SERS database to HDF5 format.
%
%   exportDatabaseToHDF5(db, h5File)
%
%   Serializes the hierarchical database struct into a native HDF5 file.
%   - Struct branches become HDF5 Groups.
%   - Numeric arrays (numel > 2) become HDF5 Datasets.
%   - Scalars, small vectors (<= 2), and strings become Group Attributes.
%   - Function handles and class objects (like dlnetwork) are skipped.
%
%   Input:
%       db     - Unified database struct (from createDatabaseStruct)
%       h5File - string, path to output .h5 file
%
%   Example:
%       exportDatabaseToHDF5(db, "sers_database.h5");
%
%   See also: importDatabaseFromHDF5, createDatabaseStruct

    arguments
        db (1,1) struct
        h5File (1,1) string
    end

    % Delete existing file if it exists
    if isfile(h5File)
        delete(h5File);
    end

    % Create root group implicitly by writing to it
    % Walk the struct recursively
    walkStruct(db, "/", h5File);
    
    fprintf('Successfully exported database to %s\n', h5File);
end

function walkStruct(s, currentPath, h5File)
    fields = fieldnames(s);
    
    for i = 1:numel(fields)
        fn = fields{i};
        val = s.(fn);
        
        % Construct HDF5 path
        if strcmp(currentPath, "/")
            h5path = "/" + string(fn);
        else
            h5path = currentPath + "/" + string(fn);
        end
        
        if isstruct(val)
            % It's a nested struct -> HDF5 Group
            % We don't need to explicitly create groups in MATLAB's high-level
            % HDF5 interface; they are created when datasets/attributes are written.
            % But if the struct is empty, we might want to create an empty group.
            % For simplicity, we just recurse.
            walkStruct(val, h5path, h5File);
            
        elseif isstring(val) || ischar(val)
            % String -> Attribute on the parent group
            % h5writeatt requires the group to exist, so we write to the root
            % if currentPath is "/", otherwise to currentPath.
            % The attribute name is fn.
            writeAttribute(h5File, currentPath, fn, string(val));
            
        elseif isnumeric(val) || islogical(val)
            if isempty(val)
                continue; % Skip empty arrays
            end
            
            if numel(val) <= 2 && isvector(val)
                % Scalar or small vector (e.g., StokesWindow [1x2]) -> Attribute
                writeAttribute(h5File, currentPath, fn, double(val));
            else
                % Larger array -> Dataset
                % MATLAB uses column-major, HDF5 uses row-major.
                % h5create/h5write handles this transparently for MATLAB users,
                % but Python users will see transposed dimensions.
                % We write it as-is.
                
                % Convert logical to uint8 for HDF5 compatibility
                if islogical(val)
                    val = uint8(val);
                end
                
                % Create dataset and write
                try
                    h5create(h5File, h5path, size(val), 'Datatype', class(val));
                    h5write(h5File, h5path, val);
                catch ME
                    warning('Failed to write dataset %s: %s', h5path, ME.message);
                end
            end
            
        elseif isa(val, 'function_handle')
            % Skip function handles
            fprintf('  Skipping function handle: %s\n', h5path);
            
        elseif isobject(val)
            % Skip objects (like dlnetwork)
            fprintf('  Skipping object of class %s: %s\n', class(val), h5path);
            
        elseif iscell(val)
            % Try to handle cell arrays of strings
            if all(cellfun(@(x) isstring(x) || ischar(x), val))
                % Convert to string array and write as dataset
                strArray = string(val);
                try
                    h5create(h5File, h5path, size(strArray), 'Datatype', 'string');
                    h5write(h5File, h5path, strArray);
                catch ME
                    warning('Failed to write string cell array %s: %s', h5path, ME.message);
                end
            else
                warning('  Skipping unsupported cell array: %s', h5path);
            end
        else
            warning('  Skipping unsupported type %s: %s', class(val), h5path);
        end
    end
end

function writeAttribute(h5File, groupPath, attrName, val)
    % Ensure the group exists by creating a dummy dataset if it's the root
    % or if the file doesn't exist yet.
    if ~isfile(h5File)
        % Create an empty root group by writing a dummy attribute
        fid = H5F.create(char(h5File));
        H5F.close(fid);
    end
    
    try
        h5writeatt(h5File, groupPath, char(attrName), val);
    catch ME
        % If group doesn't exist, h5writeatt fails.
        % We can create the group using low-level HDF5 functions.
        try
            fid = H5F.open(char(h5File), 'H5F_ACC_RDWR', 'H5P_DEFAULT');
            % Check if group exists
            try
                gid = H5G.open(fid, char(groupPath));
            catch
                % Create group
                gid = H5G.create(fid, char(groupPath), 'H5P_DEFAULT', 'H5P_DEFAULT', 'H5P_DEFAULT');
            end
            H5G.close(gid);
            H5F.close(fid);
            
            % Try writing attribute again
            h5writeatt(h5File, groupPath, char(attrName), val);
        catch ME2
            warning('Failed to write attribute %s/%s: %s', groupPath, attrName, ME2.message);
        end
    end
end
