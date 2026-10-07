function cmap = loadColormap(filePath, nColors)
%LOADCOLORMAP Load an RGB colormap from a text file and interpolate.
%   cmap = loadColormap()              uses AuroraAustralis.txt (bundled)
%   cmap = loadColormap(filePath)      uses the specified file
%   cmap = loadColormap(__, nColors)   interpolates to nColors (default 256)

    if nargin < 1 || isempty(filePath)
        thisDir = fileparts(mfilename("fullpath"));
        filePath = fullfile(thisDir, "AuroraAustralis.txt");
    end
    if nargin < 2 || isempty(nColors)
        nColors = 256;
    end

    baseRgb = readmatrix(filePath, CommentStyle="%");
    if size(baseRgb, 2) == 4
        baseRgb = baseRgb(:, 1:3); % ignore alpha column if present
    end
    if size(baseRgb, 2) ~= 3
        error("loadColormap:InvalidFile", "Colormap file must contain three columns of RGB values.");
    end

    samplePos = linspace(0, 1, size(baseRgb, 1));
    queryPos = linspace(0, 1, nColors);
    cmap = interp1(samplePos, baseRgb, queryPos, "linear", "extrap");
    cmap = min(max(cmap, 0), 1); % clamp to [0,1]
end