function setup_project()
%SETUP_PROJECT Initialize MATLAB path for the ASSTEROID project.
%   Adds all source and script directories to the MATLAB path so that
%   functions can be called from any working directory. Run this once per
%   MATLAB session (or add to startup.m).
%
%   Usage:
%       setup_project          % add paths for this session
%       setup_project; savepath % persist across sessions

    root = fileparts(mfilename("fullpath"));

    % ---- Source library folders -------------------------------------------
    srcDirs = {
        fullfile(root, "src", "io")
        fullfile(root, "src", "data")
        fullfile(root, "src", "physics")
        fullfile(root, "src", "modeling")
        fullfile(root, "src", "vis")
        fullfile(root, "src", "sampling")
        fullfile(root, "src", "utils")
        fullfile(root, "src", "orchestration")
    };

    % ---- Script folders (entry points) ------------------------------------
    scriptDirs = {
        fullfile(root, "scripts", "pipeline")
        fullfile(root, "scripts", "sampling")
        fullfile(root, "scripts", "apps")
    };

    % ---- Test folder -------------------------------------------------------
    testDirs = {
        fullfile(root, "tests")
    };

    % ---- Root folder -------------------------------------------------------
    rootDir = {root};

    allDirs = [rootDir; srcDirs; scriptDirs; testDirs];

    for k = 1:numel(allDirs)
        addpath(allDirs{k});
    end

    % Ensure legacy folder is NOT on the MATLAB path to avoid shadowing modern functions
    legacyDir = fullfile(root, "legacy");
    if contains(path, legacyDir)
        try
            rmpath(legacyDir);
            fprintf("ASSTEROID: Removed legacy/ from path to prevent function shadowing.\n");
        catch
        end
    end

    fprintf("ASSTEROID: %d folders added to path.\n", numel(allDirs));
    end
