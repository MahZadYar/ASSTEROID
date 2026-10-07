function p = resolvePath(filePath, workDir)
%resolvePath Resolve file path against a working directory.
%   Returns the path as-is if it exists, or prepends workDir if relative.
%   Returns "" for empty inputs.
%
%   p = resolvePath(filePath, workDir)

    arguments
        filePath string
        workDir string = ""
    end

    if strlength(filePath) == 0
        p = "";
    elseif isfile(filePath)
        p = filePath;
    else
        p = fullfile(workDir, filePath);
    end
end
