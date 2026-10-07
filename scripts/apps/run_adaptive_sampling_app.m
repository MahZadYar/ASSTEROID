function run_adaptive_sampling_app()
    %ADAPTIVE_SAMPLING_APP Interactive GUI for adaptive parameter sampling.
    %   adaptive_sampling_app() launches an interactive web-based GUI for
    %   generating optimized COMSOL parameter sweep points using rejection
    %   sampling guided by metric-based density functions.
    %
    %   NOTE: This standalone app is maintained for backward compatibility.
    %   The unified interface is available via run_sers_app (Stage 2 tab).
    %
    %   The GUI provides:
    %     - Categorized control panels for all sampling parameters
    %     - Real-time visualization of sampling density and generated points
    %     - File browser integration for data loading
    %     - Export to COMSOL parameter format
    %
    %   Example:
    %       adaptive_sampling_app()
    %
    %   See also: adaptiveSamplingConfig, runAdaptiveSamplingWorkflow,
    %             ProgressReporter, createSamplingConfig

    % Create main figure
    fig = uifigure("Name", "Adaptive Parameter Sampling", ...
        "Position", [50 50 1400 800], ...
        "Color", [0.06 0.09 0.15], ...
        "AutoResizeChildren", "off", ...
        "CloseRequestFcn", @onClose);

    % Store application state in figure's UserData
    appState = struct( ...
        "config", [], ...
        "samples", [], ...
        "density", [], ...
        "result", [], ...
        "dataLoaded", false, ...
        "samplingComplete", false);
    fig.UserData = appState;

    % Create grid layout: HTML controls on left, axes on right
    mainGrid = uigridlayout(fig, [1, 2]);
    mainGrid.ColumnWidth = {420, "1x"};
    mainGrid.Padding = [0 0 0 0];
    mainGrid.ColumnSpacing = 0;

    % Create HTML component for controls (left panel)
    htmlPanel = uihtml(mainGrid);
    htmlPanel.Layout.Column = 1;
    htmlPanel.HTMLSource = fullfile(fileparts(mfilename("fullpath")), "adaptive_sampling_app.html");
    htmlPanel.HTMLEventReceivedFcn = @(src, event) handleHTMLEvent(src, event, fig);

    % Create visualization panel (right side)
    vizPanel = uipanel(mainGrid, ...
        "BackgroundColor", [0.06 0.09 0.15], ...
        "BorderType", "none");
    vizPanel.Layout.Column = 2;

    % Create axes for visualization (fill the panel)
    ax = uiaxes(vizPanel, ...
        "Units", "normalized", ...
        "Position", [0.05 0.05 0.9 0.9], ...
        "Color", [0.12 0.15 0.21], ...
        "XColor", [0.7 0.75 0.8], ...
        "YColor", [0.7 0.75 0.8], ...
        "GridColor", [0.3 0.35 0.4], ...
        "GridAlpha", 0.5, ...
        "Box", "on");
    ax.XGrid = "on";
    ax.YGrid = "on";
    xlabel(ax, "Period (nm)", "Color", [0.9 0.92 0.95], "FontWeight", "bold");
    ylabel(ax, "Radius (nm)", "Color", [0.9 0.92 0.95], "FontWeight", "bold");
    title(ax, "Sampling Density & Generated Points", "Color", [0.9 0.92 0.95]);

    % Store handles
    handles = struct( ...
        "fig", fig, ...
        "htmlPanel", htmlPanel, ...
        "vizPanel", vizPanel, ...
        "ax", ax);
    setappdata(fig, "Handles", handles);

    % Load default colormap
    loadCustomColormap(fig);
end

%% Close Callback
function onClose(fig, ~)
    delete(fig);
end

%% Main Event Handler
function handleHTMLEvent(src, event, fig)
    eventName = event.HTMLEventName;
    eventData = event.HTMLEventData;

    try
        switch eventName
            case "BrowseWorkDir"
                browseWorkDir(src, fig);

            case "BrowseDataFile"
                browseDataFile(src, fig);

            case "BrowsePredictionFile"
                browsePredictionFile(src, fig);

            case "LoadData"
                loadData(src, fig, eventData);

            case "RunSampling"
                runSampling(src, fig, eventData);

            case "PreviewDensity"
                previewDensity(src, fig, eventData);

            case "ExportResults"
                exportResults(src, fig, eventData);

            case "Reset"
                resetApp(src, fig);

            case {"StopProcess", "StopSampling"}
                if isfield(fig.UserData, "stopRequested")
                    appState = fig.UserData;
                    appState.stopRequested = true;
                    fig.UserData = appState;
                end
                sendEventToHTMLSource(src, "ProcessStopAck", "Stopping sampling process...");

            otherwise
                fprintf("Unknown event: %s\n", eventName);
        end

    catch ME
        fprintf("Error handling event %s: %s\n", eventName, ME.message);
        sendEventToHTMLSource(src, "Error", ME.message);
    end
end

%% File Browser Functions
function browseWorkDir(src, ~)
    folder = uigetdir(pwd, "Select Working Directory");
    if folder ~= 0
        sendEventToHTMLSource(src, "ConfigLoaded", struct("workDir", folder));
    end
end

function browseDataFile(src, fig)
    appState = fig.UserData;
    startPath = pwd;
    if isstruct(appState.config) && isfield(appState.config, "workDir") && ~isempty(appState.config.workDir)
        startPath = appState.config.workDir;
    end

    [file, path] = uigetfile({"*.mat;*.csv", "Data Files (*.mat, *.csv)"}, ...
        "Select Data File", startPath);
    if file ~= 0
        fullPath = fullfile(path, file);
        sendEventToHTMLSource(src, "ConfigLoaded", struct("dataFile", fullPath, "workDir", path));
        
        % Auto-load the data
        pause(0.1); % Brief pause to ensure HTML updates
        handles = getappdata(fig, "Handles");
        % Trigger load with a dummy eventData structure
        dummyEvent = struct("HTMLEventName", "LoadData", "HTMLEventData", struct());
        handleHTMLEvent(handles.htmlPanel, dummyEvent, fig);
    end
end

function browsePredictionFile(src, fig)
    appState = fig.UserData;
    startPath = pwd;
    if isstruct(appState.config) && isfield(appState.config, "workDir") && ~isempty(appState.config.workDir)
        startPath = appState.config.workDir;
    end

    [file, path] = uigetfile({"*.mat", "MAT Files (*.mat)"}, ...
        "Select Prediction File", startPath);
    if file ~= 0
        fullPath = fullfile(path, file);
        sendEventToHTMLSource(src, "ConfigLoaded", struct("predictionFile", fullPath, "workDir", path));
        
        % Auto-load the data
        pause(0.1); % Brief pause to ensure HTML updates
        handles = getappdata(fig, "Handles");
        % Trigger load with a dummy eventData structure
        dummyEvent = struct("HTMLEventName", "LoadData", "HTMLEventData", struct());
        handleHTMLEvent(handles.htmlPanel, dummyEvent, fig);
    end
end

%% Load Data
function loadData(src, fig, eventData)
    appState = fig.UserData;

    % Build configuration from event data
    cfg = buildConfigFromEventData(eventData);
    appState.config = cfg;

    % Validate required fields
    if cfg.fromPredictions
        if isempty(cfg.predictionFile)
            sendEventToHTMLSource(src, "Error", "Please select a prediction file");
            return
        end
    else
        if isempty(cfg.dataFile)
            sendEventToHTMLSource(src, "Error", "Please select a data file");
            return
        end
    end

    sendEventToHTMLSource(src, "StatusUpdate", "Loading data...");

    % Load data using pipeline function
    try
        samples = loadSamplingData(cfg);
        appState.samples = samples;
        appState.dataLoaded = true;
        fig.UserData = appState;

        % Extract available metric field names from allData
        availableMetrics = string([]);
        if isfield(samples, "allData") && isstruct(samples.allData)
            allData = samples.allData;
            fieldNames = fieldnames(allData);
            validMetrics = {};
            
            for i = 1:numel(fieldNames)
                fieldName = fieldNames{i};
                % Skip geometry parameters
                if ismember(fieldName, {'period', 'radius', 'p', 'r'})
                    continue
                end
                
                % Check field dimensionality
                fieldData = allData.(fieldName);
                fieldSize = size(fieldData);
                
                % Only include fields that are column vectors matching numPoints
                if numel(fieldSize) == 2 && fieldSize(1) == samples.numPoints && fieldSize(2) == 1
                    validMetrics{end+1} = fieldName;
                else
                    % Warn about skipped multi-dimensional field
                    fprintf("Info: Skipping field '%s' - shape is %s (expected %d×1)\n", ...
                        fieldName, mat2str(fieldSize), samples.numPoints);
                end
            end
            
            availableMetrics = string(validMetrics');
        end

        % Send success response with available metrics
        pMin = min(samples.period);
        pMax = max(samples.period);
        rMin = min(samples.radius);
        rMax = max(samples.radius);
        inputParams = [ ...
            struct('name', 'period', 'min', pMin, 'max', pMax), ...
            struct('name', 'radius', 'min', rMin, 'max', rMax) ...
        ];

        response = struct( ...
            "numPoints", samples.numPoints, ...
            "periodMin", pMin, ...
            "periodMax", pMax, ...
            "radiusMin", rMin, ...
            "radiusMax", rMax, ...
            "inputParams", inputParams, ...
            "availableMetrics", availableMetrics);

        sendEventToHTMLSource(src, "DataLoaded", response);

        % Update visualization with data points
        updateVisualization(fig, cfg, samples, [], []);

    catch ME
        sendEventToHTMLSource(src, "Error", "Failed to load data: " + ME.message);
    end
end

%% Run Sampling
function runSampling(src, fig, eventData)
    appState = fig.UserData;

    if ~appState.dataLoaded
        sendEventToHTMLSource(src, "Error", "Please load data first");
        return
    end

    % Build configuration
    cfg = buildConfigFromEventData(eventData);
    appState.config = cfg;

    % Validate that metrics are selected for sampling
    if isempty(cfg.metricNames)
        sendEventToHTMLSource(src, "Error", "Please select at least one metric before running sampling");
        return
    end

    sendEventToHTMLSource(src, "StatusUpdate", "Building sampling density...");
    sendEventToHTMLSource(src, "SamplingProgress", struct("percent", 5, "message", "Building density function..."));

    appState = fig.UserData;
    appState.stopRequested = false;
    appState.isRunning = true;
    fig.UserData = appState;
    cleanupObj = onCleanup(@() localSamplingCleanup(fig));
    cfg.stopFcn = @() localIsSamplingStopRequested(fig);

    try
        % Re-extract metrics if metric names have changed
        samples = updateSamplesMetrics(appState.samples, cfg);
        appState.samples = samples;  % Update stored samples
        
        % Build density function
        density = buildSamplingDensity(cfg, samples);
        appState.density = density;

        sendEventToHTMLSource(src, "SamplingProgress", struct("percent", 15, "message", "Running rejection sampling..."));

        % Run sampling using the library function (single code path)
        result = runAdaptiveSampling(cfg, samples, density);
        appState.result = result;
        appState.samplingComplete = true;
        fig.UserData = appState;

        sendEventToHTMLSource(src, "SamplingProgress", struct("percent", 100, "message", "Complete!"));

        % Send completion response
        response = struct( ...
            "count", result.count, ...
            "attempts", result.attempts, ...
            "acceptanceRate", result.acceptanceRate);

        sendEventToHTMLSource(src, "SamplingComplete", response);

        % Update visualization
        updateVisualization(fig, cfg, samples, density, result);

    catch ME
        if localIsSamplingStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            sendEventToHTMLSource(src, "ProcessStopped", struct("stage", "Sampling", "message", "Sampling terminated by user."));
            sendEventToHTMLSource(src, "SamplingStopped", "Sampling terminated by user.");
            return;
        end
        sendEventToHTMLSource(src, "Error", "Sampling failed: " + ME.message);
    end
end

function localSamplingCleanup(fig)
    if isvalid(fig) && isfield(fig.UserData, "isRunning")
        appState = fig.UserData;
        appState.isRunning = false;
        appState.stopRequested = false;
        fig.UserData = appState;
    end
end

function stopReq = localIsSamplingStopRequested(fig)
    stopReq = false;
    if isvalid(fig) && isfield(fig.UserData, "stopRequested")
        stopReq = logical(fig.UserData.stopRequested);
    end
end

%% Preview Density
function previewDensity(src, fig, eventData)
    appState = fig.UserData;

    if ~appState.dataLoaded
        sendEventToHTMLSource(src, "Error", "Please load data first");
        return
    end

    cfg = buildConfigFromEventData(eventData);
    appState.config = cfg;

    % Validate that metrics are selected for density preview
    if isempty(cfg.metricNames)
        sendEventToHTMLSource(src, "Error", "Please select at least one metric before previewing density");
        return
    end

    sendEventToHTMLSource(src, "StatusUpdate", "Building density preview...");

    try
        % Re-extract metrics if metric names have changed
        samples = updateSamplesMetrics(appState.samples, cfg);
        appState.samples = samples;  % Update stored samples
        fig.UserData = appState;
        
        % Debug: verify metrics matrix size
        fprintf("Metrics matrix size: %s, numMetrics in cfg: %d\n", ...
            mat2str(size(samples.metrics)), numel(cfg.metricNames));
        
        density = buildSamplingDensity(cfg, samples);
        appState.density = density;
        fig.UserData = appState;

        % Update visualization with density only
        updateVisualization(fig, cfg, samples, density, appState.result);

        sendEventToHTMLSource(src, "DensityPreview", struct("success", true));

    catch ME
        sendEventToHTMLSource(src, "Error", "Density preview failed: " + ME.message);
    end
end

%% Export Results
function exportResults(src, fig, eventData)
    appState = fig.UserData;

    if ~appState.samplingComplete || isempty(appState.result)
        sendEventToHTMLSource(src, "Error", "No sampling results to export. Run sampling first.");
        return
    end

    % Get output parameters from eventData
    paramName1 = 'period';
    paramName2 = 'radius';
    paramUnit1 = 'nm';
    paramUnit2 = 'nm';
    
    if isfield(eventData, 'paramName1') && ~isempty(eventData.paramName1)
        paramName1 = eventData.paramName1;
    end
    if isfield(eventData, 'paramName2') && ~isempty(eventData.paramName2)
        paramName2 = eventData.paramName2;
    end
    if isfield(eventData, 'paramUnit1') && ~isempty(eventData.paramUnit1)
        paramUnit1 = eventData.paramUnit1;
    end
    if isfield(eventData, 'paramUnit2') && ~isempty(eventData.paramUnit2)
        paramUnit2 = eventData.paramUnit2;
    end

    % Build default output path
    workDir = '';
    outputFile = 'adaptive_points.txt';
    
    if isfield(eventData, 'workDir') && ~isempty(eventData.workDir)
        workDir = eventData.workDir;
    end
    if isfield(eventData, 'outputFile') && ~isempty(eventData.outputFile)
        outputFile = eventData.outputFile;
    end
    
    if ~isempty(workDir)
        defaultPath = fullfile(workDir, outputFile);
    else
        defaultPath = fullfile(pwd, outputFile);
    end

    % Open dialogue browser for saving the txt file
    [file, path] = uiputfile({'*.txt', 'Text Files (*.txt)'; '*.*', 'All Files (*.*)'}, ...
        'Save Export File As', defaultPath);
        
    if isequal(file, 0) || isequal(path, 0)
        sendEventToHTMLSource(src, "StatusUpdate", "Export cancelled.");
        return;
    end
    
    outputPath = fullfile(path, file);

    try
        % Build original points array if needed
        originalPoints = [appState.samples.period(:), appState.samples.radius(:)];

        % Get precision from eventData
        precision = 6;
        if isfield(eventData, 'precision')
            precision = eventData.precision;
        end
        
        % Get includeOriginal flag
        includeOriginal = false;
        if isfield(eventData, 'includeOriginal')
            includeOriginal = eventData.includeOriginal;
        end

        % Export using pipeline function
        exportToComsol(appState.result, ...
            OutputFile=outputPath, ...
            ParamNames={paramName1, paramName2}, ...
            ParamUnits={paramUnit1, paramUnit2}, ...
            Precision=precision, ...
            IncludeOriginal=includeOriginal, ...
            OriginalPoints=originalPoints);

        sendEventToHTMLSource(src, "ExportComplete", struct("filename", outputPath));

    catch ME
        sendEventToHTMLSource(src, "Error", "Export failed: " + ME.message);
    end
end

%% Reset Application
function resetApp(src, fig)
    % Clear state
    appState = struct( ...
        "config", [], ...
        "samples", [], ...
        "density", [], ...
        "result", [], ...
        "dataLoaded", false, ...
        "samplingComplete", false);
    fig.UserData = appState;

    % Clear axes
    handles = getappdata(fig, "Handles");
    cla(handles.ax);
    title(handles.ax, "Sampling Density & Generated Points", "Color", [0.9 0.92 0.95]);

    sendEventToHTMLSource(src, "StatusUpdate", "Reset complete");
end

%% Update Samples Metrics
function samples = updateSamplesMetrics(samples, cfg)
    %UPDATESAMPLESMETRICS Re-extract metrics from raw data based on config names.
    %   Always re-extracts metrics to ensure samples.metrics matches cfg.metricNames.

    if isempty(samples)
        return;
    end

    newNames = cfg.metricNames;
    if isempty(newNames)
        fprintf("Warning: No metric names in config\n");
        return;
    end

    newNames = string(newNames);
    numMetrics = numel(newNames);
    numPoints = samples.numPoints;

    try
        fprintf("Extracting %d metrics for %d points...\n", numMetrics, numPoints);
        [metrics, resolvedNames] = extractSamplingMetrics(samples, newNames, numPoints);

        for i = 1:numMetrics
            fprintf("  [%d] %s -> resolved as '%s', range [%.2g, %.2g]\n", ...
                i, newNames(i), resolvedNames(i), min(metrics(:,i)), max(metrics(:,i)));
        end

        samples.metrics = metrics;
        samples.metricNames = cellstr(newNames);
        samples.numMetrics = numMetrics;
        samples.resolvedMetricNames = resolvedNames;
        fprintf("Updated samples.metrics: size = %s\n", mat2str(size(samples.metrics)));
    catch ME
        fprintf("Error in updateSamplesMetrics: %s\n", ME.message);
        rethrow(ME);
    end
end

%% Update Visualization
function updateVisualization(fig, cfg, samples, density, result)
    handles = getappdata(fig, "Handles");
    ax = handles.ax;

    cla(ax);
    hold(ax, "on");

    % Determine ranges
    if cfg.useManualRange && ~isnan(cfg.periodRange(1))
        pRange = cfg.periodRange;
        rRange = cfg.radiusRange;
    else
        pRange = [min(samples.period), max(samples.period)];
        rRange = [min(samples.radius), max(samples.radius)];
    end

    % Initialize density value for z-ordering
    maxD = 1;

    % Plot density heatmap if available
    if ~isempty(density) && ~cfg.uniformSampling
        gridRes = cfg.gridResolution;
        pGrid = linspace(pRange(1), pRange(2), gridRes);
        rGrid = linspace(rRange(1), rRange(2), gridRes);
        [PG, RG] = meshgrid(pGrid, rGrid);

        % Evaluate density
        D = density.func(PG(:), RG(:));
        D = reshape(D, size(PG));
        D(isnan(D)) = 0;
        maxD = max(D(:)) + 0.01;

        % Plot as surface
        surf(ax, PG, RG, D, "EdgeColor", "none", "FaceAlpha", 0.9);
        view(ax, 2);

        % Apply colormap
        applyColormap(fig, ax);

        % Add colorbar
        cb = colorbar(ax);
        cb.Color = [0.7 0.75 0.8];
        cb.Label.String = "Sampling Density";
        cb.Label.Color = [0.9 0.92 0.95];
        clim(ax, [0 1]);
    else
        % Uniform sampling - show simple 2D view
        view(ax, 2);
    end

    % Plot original points
    if cfg.showOriginal && ~isempty(samples)
        origColor = hex2rgb(cfg.originalColor);
        scatter3(ax, samples.period, samples.radius, ...
            ones(size(samples.period)) * 1.1 * maxD, ...
            cfg.pointSize, origColor, "filled", ...
            "MarkerEdgeColor", "k", "LineWidth", 0.5, ...
            "DisplayName", "Original Data");
    end

    % Plot generated points
    if cfg.showGenerated && ~isempty(result) && result.count > 0
        genColor = hex2rgb(cfg.generatedColor);
        scatter3(ax, result.points(:,1), result.points(:,2), ...
            ones(result.count, 1) * 1.2 * maxD, ...
            cfg.pointSize * 1.2, genColor, "filled", ...
            "MarkerEdgeColor", "w", "LineWidth", 0.5, ...
            "DisplayName", sprintf("Generated (%d)", result.count));
    end

    hold(ax, "off");

    % Set axis limits and labels
    xlim(ax, pRange);
    ylim(ax, rRange);
    xlabel(ax, "Period (nm)", "Color", [0.9 0.92 0.95], "FontWeight", "bold");
    ylabel(ax, "Radius (nm)", "Color", [0.9 0.92 0.95], "FontWeight", "bold");

    % Build title
    if ~isempty(result) && result.count > 0
        titleStr = sprintf("Generated %d points (%.2f%% acceptance)", ...
            result.count, result.acceptanceRate * 100);
    else
        titleStr = "Sampling Density Preview";
    end
    title(ax, titleStr, "Color", [0.9 0.92 0.95], "FontSize", 12);

    legend(ax, "Location", "northeast", "TextColor", [0.9 0.92 0.95], ...
        "Color", [0.2 0.25 0.3], "EdgeColor", [0.4 0.45 0.5]);

    drawnow;
end

%% Build Configuration from Event Data
function cfg = buildConfigFromEventData(eventData)
    % Convert JavaScript event data to MATLAB config struct.
    % Delegates pipeline parameters to adaptiveSamplingConfig for validation
    % and augments with UI-specific fields.

    % --- Helper for safe field access ---
    getField = @(name, default) ternary(isfield(eventData, name), eventData.(name), default);
    getStrField = @(name, default) string(getField(name, default));

    % --- Resolve parameter ranges ---
    if isfield(eventData, 'autoDetectRanges') && eventData.autoDetectRanges
        periodRange = [NaN, NaN];
        radiusRange = [NaN, NaN];
    elseif isfield(eventData, 'periodMin') && isfield(eventData, 'periodMax')
        periodRange = [eventData.periodMin, eventData.periodMax];
        radiusRange = [eventData.radiusMin, eventData.radiusMax];
    else
        periodRange = [NaN, NaN];
        radiusRange = [NaN, NaN];
    end

    % --- Sanitise metric arrays from JavaScript ---
    metricNames = sanitiseMetricArray(getField('metricNames', []));
    numMetrics = max(1, numel(metricNames));

    metricWeights = sanitiseNumericArray(getField('metricWeights', []), numMetrics);
    metricAlphas  = sanitiseNumericArray(getField('metricAlphas', []),  numMetrics);

    % --- Build pipeline config via orchestration layer ---
    if isempty(metricNames)
        metricNames = "EF_vol_avg";
    end

    cfg = adaptiveSamplingConfig( ...
        WorkDir         = getStrField('workDir', ''), ...
        DataFile        = getStrField('dataFile', ''), ...
        FromPredictions = getField('fromPredictions', false), ...
        PredictionFile  = getStrField('predictionFile', ''), ...
        NumPoints       = getField('numPoints', 100), ...
        MaxAttempts     = getField('maxAttempts', 1e6), ...
        MinSeparation   = getField('minSeparation', 5), ...
        RtpThreshold    = getField('rtpThreshold', 0.49), ...
        UniformSampling = getField('uniformSampling', false), ...
        EnforceOriginalSpacing = getField('enforceOriginalSpacing', true), ...
        PeriodRange     = periodRange, ...
        RadiusRange     = radiusRange, ...
        MetricNames     = metricNames, ...
        MetricWeights   = metricWeights, ...
        MetricAlphas    = metricAlphas, ...
        OverallExponent = getField('overallExponent', 1), ...
        BlurSigma       = getField('blurSigma', 0), ...
        OutputFile      = getStrField('outputFile', 'adaptive_points.txt'), ...
        DensityThreshold = getField('densityThreshold', 0), ...
        GridResolution  = getField('gridResolution', 100), ...
        Visualize       = false);  % App renders its own axes

    % --- Augment with UI-specific display fields ---
    cfg.showOriginal   = getField('showOriginal', true);
    cfg.showGenerated  = getField('showGenerated', true);
    cfg.originalColor  = getStrField('originalColor', '#ef4444');
    cfg.generatedColor = getStrField('generatedColor', '#10b981');
    cfg.pointSize      = getField('pointSize', 30);
    cfg.colormap       = getStrField('colormap', 'custom');
end

%% Sanitise metric name arrays from JavaScript
function names = sanitiseMetricArray(raw)
    if isempty(raw)
        names = string.empty(1, 0);
        return
    end
    if iscell(raw)
        while isscalar(raw) && iscell(raw{1})
            raw = raw{1};
        end
    end
    names = string(raw);
    names = names(~ismissing(names) & strlength(strtrim(names)) > 0);
    names = reshape(names, 1, []);
end

%% Sanitise numeric arrays from JavaScript
function vec = sanitiseNumericArray(raw, targetLen)
    if isempty(raw)
        vec = ones(1, targetLen);
        return
    end
    if iscell(raw)
        while isscalar(raw) && iscell(raw{1})
            raw = raw{1};
        end
        try
            vec = cell2mat(raw);
        catch
            vec = cellfun(@double, raw);
        end
    elseif isstring(raw)
        vec = double(raw);
    else
        vec = double(raw);
    end
    vec = vec(:)';
    if numel(vec) < targetLen
        vec = [vec, ones(1, targetLen - numel(vec))];
    elseif numel(vec) > targetLen
        vec = vec(1:targetLen);
    end
end

%% Helper function for ternary operator
function result = ternary(condition, trueVal, falseVal)
    if condition
        result = trueVal;
    else
        result = falseVal;
    end
end

%% Load Custom Colormap
function loadCustomColormap(fig)
    colormapFile = fullfile(fileparts(mfilename("fullpath")), "AuroraAustralis.txt");
    if isfile(colormapFile)
        try
            % Load via utility to ensure proper interpolation/clamping
            cmap = loadColormap(colormapFile, 256);
            % Flip so lower values map to darker end
            cmap = flipud(cmap);
            setappdata(fig, "CustomColormap", cmap);
        catch
            setappdata(fig, "CustomColormap", parula(256));
        end
    else
        setappdata(fig, "CustomColormap", parula(256));
    end
end

%% Apply Colormap
function applyColormap(fig, ax)
    handles = getappdata(fig, "Handles");
    appState = fig.UserData;

    if isfield(appState.config, "colormap")
        cmapName = appState.config.colormap;
    else
        cmapName = "custom";
    end

    if cmapName == "custom"
        cmap = getappdata(fig, "CustomColormap");
        if isempty(cmap)
            cmap = parula(256);
        end
    else
        try
            cmapFunc = str2func(cmapName);
            cmap = cmapFunc(256);
        catch
            cmap = parula(256);
        end
    end

    colormap(ax, cmap);
end

%% Utility: Hex to RGB
function rgb = hex2rgb(hexColor)
    %HEX2RGB Convert hex color string to RGB triplet.
    hexColor = char(hexColor);
    if hexColor(1) == "#"
        hexColor = hexColor(2:end);
    end
    rgb = [hex2dec(hexColor(1:2)), hex2dec(hexColor(3:4)), hex2dec(hexColor(5:6))] / 255;
end
