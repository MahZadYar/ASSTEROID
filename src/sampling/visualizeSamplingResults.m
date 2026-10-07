function visualizeSamplingResults(cfg, samples, density, result, options)
% visualizeSamplingResults  Plot sampling density and generated points.
%
%   visualizeSamplingResults(cfg, samples, density, result) creates a
%   visualization showing the sampling density as a heatmap with overlaid
%   original and generated sample points.
%
%   visualizeSamplingResults(..., Name=Value) allows customization of the
%   plot appearance.
%
%   Input:
%       cfg     - Configuration struct from createSamplingConfig
%       samples - Samples struct from loadSamplingData
%       density - Density struct from buildSamplingDensity
%       result  - Result struct from runAdaptiveSampling
%
%   Optional Name-Value Arguments:
%       GridResolution   - Number of grid points for density image (default: 500)
%       ShowOriginal     - Display original data points (default: true)
%       ShowGenerated    - Display generated points (default: true)
%       Colormap         - Colormap name or matrix (default: "parula")
%       ColormapFile     - Path to custom colormap file
%       OriginalColor    - Color for original points (default: "r")
%       GeneratedColor   - Color for generated points (default: "g")
%       PointSize        - Marker size for scatter points (default: 10)
%       Title            - Custom plot title
%       SaveFigure       - If true, save figure to file
%       OutputFile       - Filename for saved figure
%
%   Example:
%       visualizeSamplingResults(cfg, samples, density, result, ...
%           GridResolution=200, ...
%           Colormap="hot", ...
%           Title="Adaptive Sampling Results");
%
%   See also: runAdaptiveSampling, exportToComsol

arguments
    cfg (1,1) struct
    samples (1,1) struct
    density (1,1) struct
    result (1,1) struct
    options.GridResolution (1,1) double {mustBePositive} = 500
    options.ShowOriginal (1,1) logical = true
    options.ShowGenerated (1,1) logical = true
    options.Colormap = "parula"
    options.ColormapFile (1,1) string = ""
    options.OriginalColor = "r"
    options.GeneratedColor = "g"
    options.PointSize (1,1) double {mustBePositive} = 10
    options.Title (1,1) string = ""
    options.SaveFigure (1,1) logical = false
    options.OutputFile (1,1) string = "sampling_results.png"
end

% Create figure
fig = figure("Name", "Adaptive Sampling Results", "Color", "w");

% Build visualization grid
gridRes = options.GridResolution;
pGrid = linspace(density.periodRange(1), density.periodRange(2), gridRes);
rGrid = linspace(density.radiusRange(1), density.radiusRange(2), gridRes);
[PG, RG] = meshgrid(pGrid, rGrid);

% Evaluate density on grid
DG = density.func(PG, RG);
DG(isnan(DG)) = 0;

% Plot density heatmap
pcolor(PG, RG, DG);
shading interp;
hold on;

% Apply colormap
cmap = loadColormapFromOption(options.Colormap, options.ColormapFile);
colormap(cmap);
set(gca, "YDir", "normal");

% Plot original points
if options.ShowOriginal && ~cfg.fromPredictions
    scatter(samples.period, samples.radius, options.PointSize, ...
        options.OriginalColor, "filled", "MarkerFaceAlpha", 0.7, ...
        "DisplayName", "Original Points");
end

% Plot generated points
if options.ShowGenerated && result.count > 0
    scatter(result.points(:, 1), result.points(:, 2), options.PointSize, ...
        options.GeneratedColor, "filled", "MarkerFaceAlpha", 0.9, ...
        "DisplayName", "Generated Points");
end

% Configure axes
colorbar();
clim([0 1]);
xlim(density.periodRange);
ylim(density.radiusRange);
xlabel("Period (nm)");
ylabel("Radius (nm)");
grid on;
legend("Location", "best");
axis tight;

% Set title
if options.Title ~= ""
    title(options.Title);
else
    title(sprintf("Adaptive Sampling (N=%d, acceptance=%.1f%%)", ...
        result.count, 100 * result.acceptanceRate));
end

% Save figure if requested
if options.SaveFigure
    saveas(fig, options.OutputFile);
    fprintf("Figure saved to: %s\n", options.OutputFile);
end

end

%% ========================================================================
function cmap = loadColormapFromOption(cmapOption, cmapFile)
% loadColormapFromOption  Load colormap from various sources.

% Try loading from file first
if cmapFile ~= ""
    try
        cmap = loadColormapFromFile(cmapFile);
        return;
    catch
        warning("visualizeSamplingResults:ColormapFileError", ...
            "Could not load colormap from file: %s", cmapFile);
    end
end

% Check if cmapOption is a matrix
if isnumeric(cmapOption) && size(cmapOption, 2) == 3
    cmap = cmapOption;
    return;
end

% Try standard colormap name
try
    cmapFunc = str2func(cmapOption);
    cmap = cmapFunc(256);
catch
    cmap = parula(256);
end
end

%% ========================================================================
function cmap = loadColormapFromFile(filename)
% loadColormapFromFile  Load colormap from text file.

if ~isfile(filename)
    error("Colormap file not found: %s", filename);
end

data = readmatrix(filename);

% Normalize to [0, 1] if necessary
if max(data(:)) > 1
    data = data / 255;
end

cmap = data;
end
