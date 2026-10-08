function run_prediction_vis_app()
% run_prediction_vis_app  Launch interactive SERS prediction visualization app.
%
% This function creates an interactive uihtml-based application for
% visualizing SERS enhancement factor predictions. The app allows users
% to configure all prediction and visualization parameters through a
% modern web interface.
%
% NOTE: This standalone app is maintained for backward compatibility.
% The unified interface is available via run_sers_app (Stage 5 tab).

    % Singleton guard: if an instance is already running, focus it
    existing = findall(groot, "Tag", "ASSTEROID_PRED_VIS_APP");
    if isempty(existing)
        allFigs = findall(groot, "Type", "figure");
        for k = 1:numel(allFigs)
            if contains(string(allFigs(k).Name), "SERS Prediction Visualizer")
                existing = allFigs(k);
                break;
            end
        end
    end
    if ~isempty(existing) && isvalid(existing(1))
        fig = existing(1);
        uistack(fig, "top");
        try focus(fig); catch; end
        return;
    end

    %% Create main figure
    screenSize = get(0, "ScreenSize");
    figWidth = min(1600, screenSize(3) - 100);
    figHeight = min(1000, screenSize(4) - 100);
    figX = (screenSize(3) - figWidth) / 2;
    figY = (screenSize(4) - figHeight) / 2;

    fig = uifigure("Name", "SERS Prediction Visualizer", ...
        "Tag", "ASSTEROID_PRED_VIS_APP", ...
        "Position", [figX figY figWidth figHeight], ...
        "Color", [0.15 0.15 0.18], ...
        "Resize", "on");

    %% Initialize app state FIRST before any UI components
    fig.UserData = struct();
    fig.UserData.state = initializeState();

    %% Create layout
    mainGrid = uigridlayout(fig, [1 2]);
    mainGrid.ColumnWidth = {400, "1x"};
    mainGrid.Padding = [10 10 10 10];
    mainGrid.ColumnSpacing = 10;
    mainGrid.BackgroundColor = [0.15 0.15 0.18];

    %% Left panel: HTML controls with grid layout for proper sizing
    htmlPanel = uipanel(mainGrid, ...
        "Title", "", ...
        "BackgroundColor", [0.18 0.18 0.22], ...
        "BorderType", "none");
    htmlPanel.Layout.Column = 1;

    htmlGrid = uigridlayout(htmlPanel, [1 1]);
    htmlGrid.Padding = [0 0 0 0];
    htmlGrid.BackgroundColor = [0.18 0.18 0.22];

    h = uihtml(htmlGrid);
    h.HTMLSource = fullfile(fileparts(mfilename("fullpath")), "prediction_vis_app.html");
    h.HTMLEventReceivedFcn = @(src, event) handleHTMLEvent(src, event, fig);

    %% Right panel: Tab group for visualizations
    visPanel = uipanel(mainGrid, ...
        "Title", "", ...
        "BackgroundColor", [0.12 0.12 0.15], ...
        "BorderType", "none");
    visPanel.Layout.Column = 2;

    visGrid = uigridlayout(visPanel, [1 1]);
    visGrid.Padding = [5 5 5 5];
    visGrid.BackgroundColor = [0.12 0.12 0.15];

    tabGroup = uitabgroup(visGrid);

    %% Tab 1: Metric at Laser Wavelength
    tab1 = uitab(tabGroup, "Title", "Metric @ Laser λ", "BackgroundColor", [0.15 0.15 0.18]);
    tab1Grid = uigridlayout(tab1, [1 1]);
    tab1Grid.Padding = [10 10 10 10];
    tab1Grid.BackgroundColor = [0.15 0.15 0.18];

    ax1 = uiaxes(tab1Grid);
    ax1.Title.String = "Metric @ Laser Wavelength";
    ax1.Title.Color = "w";
    ax1.Title.FontSize = 14;
    ax1.XLabel.String = "Period (nm)";
    ax1.YLabel.String = "Radius (nm)";
    ax1.XColor = "w";
    ax1.YColor = "w";
    ax1.Color = [0.15 0.15 0.18];
    ax1.GridColor = [0.4 0.4 0.4];
    ax1.Tag = "axLaser";

    %% Tab 2: Spectrally Averaged Metric
    tab2 = uitab(tabGroup, "Title", "Spectral Average", "BackgroundColor", [0.15 0.15 0.18]);
    tab2Grid = uigridlayout(tab2, [1 1]);
    tab2Grid.Padding = [10 10 10 10];
    tab2Grid.BackgroundColor = [0.15 0.15 0.18];

    ax2 = uiaxes(tab2Grid);
    ax2.Title.String = "Spectrally Averaged Metric";
    ax2.Title.Color = "w";
    ax2.Title.FontSize = 14;
    ax2.XLabel.String = "Period (nm)";
    ax2.YLabel.String = "Radius (nm)";
    ax2.XColor = "w";
    ax2.YColor = "w";
    ax2.Color = [0.15 0.15 0.18];
    ax2.GridColor = [0.4 0.4 0.4];
    ax2.Tag = "axAvg";

    %% Tab 3: Spectral Profile
    tab3 = uitab(tabGroup, "Title", "Spectral Profile", "BackgroundColor", [0.15 0.15 0.18]);
    tab3Grid = uigridlayout(tab3, [1 1]);
    tab3Grid.Padding = [10 10 10 10];
    tab3Grid.BackgroundColor = [0.15 0.15 0.18];

    ax3 = uiaxes(tab3Grid);
    ax3.Title.String = "Spectral Profile at Selected Point";
    ax3.Title.Color = "w";
    ax3.Title.FontSize = 14;
    ax3.XLabel.String = "Wavelength (nm)";
    ax3.YLabel.String = "Metric Value";
    ax3.XColor = "w";
    ax3.YColor = "w";
    ax3.Color = [0.15 0.15 0.18];
    ax3.GridColor = [0.4 0.4 0.4];
    ax3.Tag = "axSpectrum";

    %% Tab 4: Wavelength Slice
    tab4 = uitab(tabGroup, "Title", "λ Slice", "BackgroundColor", [0.15 0.15 0.18]);
    tab4Grid = uigridlayout(tab4, [1 1]);
    tab4Grid.Padding = [10 10 10 10];
    tab4Grid.BackgroundColor = [0.15 0.15 0.18];

    ax4 = uiaxes(tab4Grid);
    ax4.Title.String = "Metric at Selected Wavelength";
    ax4.Title.Color = "w";
    ax4.Title.FontSize = 14;
    ax4.XLabel.String = "Period (nm)";
    ax4.YLabel.String = "Radius (nm)";
    ax4.XColor = "w";
    ax4.YColor = "w";
    ax4.Color = [0.15 0.15 0.18];
    ax4.GridColor = [0.4 0.4 0.4];
    ax4.Tag = "axSlice";

    %% Tab 5: 3D Volume Visualization
    tab5 = uitab(tabGroup, "Title", "3D Volume", "BackgroundColor", [0 0 0]);
    tab5Grid = uigridlayout(tab5, [1 1]);
    tab5Grid.Padding = [0 0 0 0];
    tab5Grid.BackgroundColor = [0 0 0];

    % Create viewer3d for volshow
    viewer3dObj = viewer3d(tab5Grid, "BackgroundColor", "black", "BackgroundGradient", "off");
    viewer3dObj.Layout.Row = 1;
    viewer3dObj.Layout.Column = 1;

    %% Store references
    fig.UserData.h = h;
    fig.UserData.axes = struct("laser", ax1, "avg", ax2, "spectrum", ax3, "slice", ax4);
    fig.UserData.tabGroup = tabGroup;
    fig.UserData.tabs = struct("laser", tab1, "avg", tab2, "spectrum", tab3, "slice", tab4, "volume", tab5);
    fig.UserData.viewer3d = viewer3dObj;
    fig.UserData.volshow = [];
    fig.UserData.visGrid = visGrid;
    fig.UserData.htmlPanel = htmlPanel;
    fig.UserData.htmlGrid = htmlGrid;

    %% Load refractive index data at startup
    riLoaded = loadRefractiveIndexData(fig);
    if riLoaded
        disp("Refractive index data loaded successfully.");
    else
        warning("Refractive index data not found. Please ensure McPeak.csv is in the working directory.");
    end

    %% Send initial state to HTML
    drawnow;
    pause(0.5); % Allow HTML to load
    sendStateToHTML(h, fig.UserData.state);
end

function state = initializeState()
% Initialize default application state
    state = struct();

    % Working directory and files
    state.workDir = pwd;
    state.riCsvFile = "McPeak.csv";
    state.riFile = "";
    state.modelFile = "";
    state.predictionFile = "";

    % Metrics configuration
    state.availableMetrics = {"Absorptance", "M_vol", "M_surf", "EF_vol", "EF_surf"};
    state.selectedMetrics = {"Absorptance", "M_vol", "M_surf"};
    state.primaryMetric = "Absorptance";

    % Grid parameters
    state.resolution = 2; % nm
    state.lambdaLaser = 785; % nm
    state.pLimits = [400, 1400]; % nm
    state.rLimits = [10, 500]; % nm
    state.stokesShiftLimits = [100, 3600]; % cm^-1
    state.stokesShiftResolution = 5; % cm^-1
    state.linkMetricsToGrid = true;
    state.metricsShiftLimits = [100, 3600]; % cm^-1

    % Analyte spectrum for weighted metrics (optional)
    state.analyteSpectrumFile = "";
    state.useAnalyteWeighting = false;
    state.analyteSpectrum = struct();

    % Visualization options
    state.colormapName = "AuroraAustralis";
    state.colormapInverted = true;
    state.logScale = false;
    state.showGrid = true;
    state.interpolation = "interp";

    % Current view state
    state.currentSliceStokes = 1000; % cm^-1
    state.selectedPoint = struct("p", 850, "r", 100); % nm

    % Data state (using SoA format)
    state.modelLoaded = false;
    state.predictionsLoaded = false;
    state.allData = [];  % SoA format predictions
    state.model = [];
    state.ri = [];
end

function handleHTMLEvent(src, event, fig)
% Handle events from HTML interface
    eventName = event.HTMLEventName;
    eventData = event.HTMLEventData;

    % Ensure state exists
    if ~isfield(fig.UserData, "state") || isempty(fig.UserData.state)
        fig.UserData.state = initializeState();
    end

    try
        switch eventName
            case "LoadModel"
                loadModel(src, eventData, fig);
            case "LoadPredictions"
                loadPredictions(src, eventData, fig);
            case "LoadRI"
                loadRI(src, eventData, fig);
            case "GeneratePredictions"
                generatePredictions(src, eventData, fig);
            case "UpdateVisualization"
                updateVisualization(src, eventData, fig);
            case "UpdateSlice"
                updateSlice(src, eventData, fig);
            case "UpdateSpectrum"
                updateSpectrum(src, eventData, fig);
            case "Update3DVolume"
                update3DVolume(src, eventData, fig);
            case "ExportGraphics"
                exportGraphics(src, eventData, fig);
            case "UpdateConfig"
                updateConfig(src, eventData, fig);
            case "BrowseFile"
                browseFile(src, eventData, fig);
            case "LoadAnalyteSpectrum"
                loadAnalyteSpectrum(src, eventData, fig);
            case "RequestState"
                sendStateToHTML(src, fig.UserData.state);
            otherwise
                warning("run_prediction_vis_app:UnknownEvent", ...
                    "Unknown event: %s", eventName);
        end
    catch ME
        fprintf("Error handling event %s: %s\n", eventName, ME.message);
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", ME.message, ...
            "event", eventName));
    end
end

function loadModel(src, eventData, fig)
% Load trained DNN model
    state = fig.UserData.state;

    if isfield(eventData, "filePath") && ~isempty(eventData.filePath)
        modelFile = string(eventData.filePath);
    else
        modelFile = fullfile(state.workDir, state.modelFile);
    end

    if ~isfile(modelFile)
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Model file not found: %s", modelFile)));
        return;
    end

    sendEventToHTMLSource(src, "Status", struct( ...
        "message", "Loading model...", "progress", 10));

    try
        modelStruct = load(modelFile, "model");
        if ~isfield(modelStruct, "model")
            error("File does not contain variable 'model'.");
        end
        fig.UserData.state.model = modelStruct.model;
        fig.UserData.state.modelLoaded = true;
        fig.UserData.state.modelFile = modelFile;

        % Load refractive index data if not already loaded
        if isempty(fig.UserData.state.ri)
            riLoaded = loadRefractiveIndexData(fig);
            if ~riLoaded
                sendEventToHTMLSource(src, "Status", struct( ...
                    "message", "Warning: RI data not found. Place McPeak.csv in working directory.", "progress", 100));
            end
        end

        sendEventToHTMLSource(src, "Status", struct( ...
            "message", "Model loaded successfully!", "progress", 100));
        sendEventToHTMLSource(src, "ModelLoaded", struct( ...
            "targets", fig.UserData.state.model.targetNames, ...
            "filePath", modelFile));
    catch ME
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Failed to load model: %s", ME.message)));
    end
end

function loadRI(src, eventData, fig)
% Load refractive index data from CSV file
    state = fig.UserData.state;

    if isfield(eventData, "filePath") && ~isempty(eventData.filePath)
        riFile = string(eventData.filePath);
    else
        riFile = fullfile(state.workDir, state.riFile);
    end

    if ~isfile(riFile)
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Refractive index file not found: %s", riFile)));
        return;
    end

    sendEventToHTMLSource(src, "Status", struct( ...
        "message", "Loading refractive index data...", "progress", 10));

    try
        fig.UserData.state.ri = load_gold_refractive_index(riFile, "WavelengthUnit", "um");
        fig.UserData.state.riFile = riFile;

        sendEventToHTMLSource(src, "Status", struct( ...
            "message", "Refractive index data loaded successfully!", "progress", 100));
        sendEventToHTMLSource(src, "RILoaded", struct( ...
            "filePath", riFile));
    catch ME
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Failed to load refractive index data: %s", ME.message)));
    end
end

function loadPredictions(src, eventData, fig)
% Load existing predictions (supports both SoA and legacy grid format)
    state = fig.UserData.state;

    if isfield(eventData, "filePath") && ~isempty(eventData.filePath)
        predFile = string(eventData.filePath);
    else
        predFile = fullfile(state.workDir, state.predictionFile);
    end

    if ~isfile(predFile)
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Predictions file not found: %s", predFile)));
        return;
    end

    sendEventToHTMLSource(src, "Status", struct( ...
        "message", "Loading predictions...", "progress", 10));

    try
        loadedData = load(predFile);
        
        % Support both SoA (allData) and legacy (predictions) format
        if isfield(loadedData, "allData")
            % New SoA format
            fig.UserData.state.allData = loadedData.allData;
            fig.UserData.state.predictionsLoaded = true;
            fig.UserData.state.predictionFile = predFile;
            
            % Extract grid info from SoA
            allData = loadedData.allData;
            pGrid = unique(allData.period) * 1e9;  % Convert to nm
            rGrid = unique(allData.radius) * 1e9;
            lambdaGrid = allData.lambda(1, :) * 1e9;
            
            % Detect available metrics
            excludeFields = ["period", "radius", "lambda", "lambda_nm", "RamanShift", ...
                "LaserWl", "lambda_exc_nm", "RamanWindow", "RamanWindowEffective", "p", "r", "particle_r", "f"];
            allFields = string(fieldnames(allData));
            metricFields = allFields(~contains(allFields, "_avg") & ~ismember(allFields, excludeFields));
            fig.UserData.state.availableMetrics = cellstr(metricFields);
            
            sendEventToHTMLSource(src, "Status", struct( ...
                "message", "Predictions loaded successfully (SoA format)!", "progress", 100));
            sendEventToHTMLSource(src, "PredictionsLoaded", struct( ...
                "metrics", metricFields, ...
                "filePath", predFile, ...
                "format", "soa", ...
                "numGeometries", size(allData.lambda, 1), ...
                "numWavelengths", size(allData.lambda, 2), ...
                "pRange", [min(pGrid) max(pGrid)], ...
                "rRange", [min(rGrid) max(rGrid)], ...
                "lambdaRange", [min(lambdaGrid) max(lambdaGrid)]));
                
        elseif isfield(loadedData, "predictions")
            % Legacy grid format - convert to SoA
            sendEventToHTMLSource(src, "Status", struct( ...
                "message", "Converting legacy format to SoA...", "progress", 50));
            
            allData = convertGridToSoA(loadedData.predictions, ...
                "LaserWavelength", state.lambdaLaser, ...
                "RamanWindow", state.stokesShiftLimits);
            
            fig.UserData.state.allData = allData;
            fig.UserData.state.predictionsLoaded = true;
            fig.UserData.state.predictionFile = predFile;
            
            % Extract grid info
            pGrid = unique(allData.period);
            rGrid = unique(allData.radius);
            lambdaGrid = allData.lambda(1, :);
            
            % Detect available metrics
            excludeFields = ["period", "radius", "lambda", "lambda_nm", "RamanShift", ...
                "LaserWl", "lambda_exc_nm", "RamanWindow", "RamanWindowEffective", "p", "r", "particle_r", "f"];
            allFields = string(fieldnames(allData));
            metricFields = allFields(~contains(allFields, "_avg") & ~ismember(allFields, excludeFields));
            fig.UserData.state.availableMetrics = cellstr(metricFields);
            
            sendEventToHTMLSource(src, "Status", struct( ...
                "message", "Legacy predictions converted to SoA format!", "progress", 100));
            sendEventToHTMLSource(src, "PredictionsLoaded", struct( ...
                "metrics", metricFields, ...
                "filePath", predFile, ...
                "format", "converted", ...
                "numGeometries", size(allData.lambda, 1), ...
                "numWavelengths", size(allData.lambda, 2), ...
                "pRange", [min(pGrid) max(pGrid)], ...
                "rRange", [min(rGrid) max(rGrid)], ...
                "lambdaRange", [min(lambdaGrid) max(lambdaGrid)]));
        else
            error("File does not contain 'allData' or 'predictions' variable.");
        end

        % Auto-update visualization
        updateVisualization(src, struct("metric", fig.UserData.state.primaryMetric), fig);
    catch ME
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Failed to load predictions: %s", ME.message)));
    end
end

function generatePredictions(src, eventData, fig)
% Generate dense predictions using loaded model (output in SoA format)
    state = fig.UserData.state;

    if ~state.modelLoaded
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", "No model loaded. Please load a model first."));
        return;
    end

    if isempty(state.ri)
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", "Refractive index data not loaded."));
        return;
    end

    % Update config from eventData
    if isfield(eventData, "resolution")
        state.resolution = eventData.resolution;
    end
    if isfield(eventData, "lambdaLaser")
        state.lambdaLaser = eventData.lambdaLaser;
    end
    if isfield(eventData, "pLimits")
        state.pLimits = eventData.pLimits;
    end
    if isfield(eventData, "rLimits")
        state.rLimits = eventData.rLimits;
    end
    if isfield(eventData, "stokesShiftLimits")
        state.stokesShiftLimits = eventData.stokesShiftLimits;
    end
    if isfield(eventData, "linkMetricsToGrid")
        state.linkMetricsToGrid = eventData.linkMetricsToGrid;
    end
    if isfield(eventData, "metricsShiftLimits")
        state.metricsShiftLimits = eventData.metricsShiftLimits;
    end

    fig.UserData.state = state;

    sendEventToHTMLSource(src, "Status", struct( ...
        "message", "Generating predictions...", "progress", 5));

    try
        % Compute sample vectors
        lambdaLimits = state.lambdaLaser ./ (1 - state.lambdaLaser * state.stokesShiftLimits * 1e-7);
        lambdaSamples = [state.lambdaLaser, linspace(lambdaLimits(1), lambdaLimits(2), ...
            round((lambdaLimits(2) - lambdaLimits(1)) / state.resolution) + 1)] * 1e-3;
        pSamples = linspace(state.pLimits(1), state.pLimits(2), ...
            round((state.pLimits(2) - state.pLimits(1)) / state.resolution) + 1) * 1e-3;
        rSamples = linspace(state.rLimits(1), state.rLimits(2), ...
            round((state.rLimits(2) - state.rLimits(1)) / state.resolution) + 1) * 1e-3;

        sendEventToHTMLSource(src, "Status", struct( ...
            "message", sprintf("Generating %dx%dx%d grid...", numel(pSamples), numel(rSamples), numel(lambdaSamples)), ...
            "progress", 20));

        % Generate predictions (returns SoA format with optional analyte-weighted metrics)
        predArgs = { ...
            "LaserWavelength", state.lambdaLaser, ...
            "RamanWindow", state.stokesShiftLimits, ...
            "AnalyteSpectrum", state.analyteSpectrum, ...
            "InterpResolution", state.stokesShiftResolution};

        % Pass separate metrics window when not linked to grid
        if isfield(state, 'linkMetricsToGrid') && ~state.linkMetricsToGrid ...
                && isfield(state, 'metricsShiftLimits') && ~isempty(state.metricsShiftLimits)
            predArgs = [predArgs, {"MetricsRamanWindow", state.metricsShiftLimits}];
        end

        allData = predict_dense_spectrum(state.model, pSamples, rSamples, lambdaSamples, state.ri, ...
            predArgs{:});

        fig.UserData.state.allData = allData;
        fig.UserData.state.predictionsLoaded = true;

        % Extract grid info from SoA (already in nm)
        pGrid = unique(allData.period);
        rGrid = unique(allData.radius);
        lambdaGrid = allData.lambda(1, :);

        % Detect available metrics
        excludeFields = ["period", "radius", "lambda", "lambda_nm", "RamanShift", ...
            "LaserWl", "lambda_exc_nm", "RamanWindow", "RamanWindowEffective", "p", "r", "particle_r", "f"];
        allFields = string(fieldnames(allData));
        metricFields = allFields(~contains(allFields, "_avg") & ~ismember(allFields, excludeFields));
        fig.UserData.state.availableMetrics = cellstr(metricFields);

        sendEventToHTMLSource(src, "Status", struct( ...
            "message", "Predictions generated successfully (SoA format)!", "progress", 100));
        sendEventToHTMLSource(src, "PredictionsLoaded", struct( ...
            "metrics", metricFields, ...
            "generated", true, ...
            "format", "soa", ...
            "numGeometries", size(allData.lambda, 1), ...
            "numWavelengths", size(allData.lambda, 2), ...
            "pRange", [min(pGrid) max(pGrid)], ...
            "rRange", [min(rGrid) max(rGrid)], ...
            "lambdaRange", [min(lambdaGrid) max(lambdaGrid)]));

        % Auto-update visualization
        updateVisualization(src, struct("metric", state.primaryMetric), fig);
    catch ME
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Failed to generate predictions: %s", ME.message)));
    end
end

function updateVisualization(src, eventData, fig)
% Update all visualization panels (using SoA format)
    state = fig.UserData.state;

    if ~state.predictionsLoaded
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", "No predictions loaded."));
        return;
    end

    if isfield(eventData, "metric")
        state.primaryMetric = string(eventData.metric);
    end
    if isfield(eventData, "logScale")
        state.logScale = eventData.logScale;
    end
    if isfield(eventData, "colormapInverted")
        state.colormapInverted = eventData.colormapInverted;
    end

    fig.UserData.state = state;

    allData = state.allData;
    metricField = matlab.lang.makeValidName(state.primaryMetric);
    metricAvgField = matlab.lang.makeValidName(state.primaryMetric + "_avg");

    if ~isfield(allData, metricField)
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Metric %s not found in predictions.", state.primaryMetric)));
        return;
    end

    % Convert SoA to volume for visualization (data already in nm)
    [metricVolume, pGrid, rGrid, lambdaGrid] = reshapeSoAToVolume(allData, metricField);

    % Load colormap
    try
        cmap = loadColormap("AuroraAustralis.txt", 256);
        if state.colormapInverted
            cmap = flipud(cmap);
        end
    catch
        cmap = parula(256);
    end

    axes = fig.UserData.axes;

    % 1. Metric at laser wavelength
    ax1 = axes.laser;
    [~, laserIdx] = min(abs(lambdaGrid - state.lambdaLaser));
    laserData = double(metricVolume(:, :, laserIdx));

    if state.logScale && all(laserData(isfinite(laserData)) > 0)
        laserData = log10(laserData);
    end

    cla(ax1);
    pcolor(ax1, pGrid, rGrid, laserData);
    shading(ax1, state.interpolation);
    colormap(ax1, cmap);
    colorbar(ax1, "Color", "w");
    ax1.Title.String = sprintf("%s @ λ = %.0f nm", strrep(state.primaryMetric, "_", "\_"), state.lambdaLaser);
    ax1.XLabel.String = "Period (nm)";
    ax1.YLabel.String = "Radius (nm)";
    if state.showGrid
        grid(ax1, "on");
    end

    % 2. Spectrally averaged metric
    ax2 = axes.avg;
    if isfield(allData, metricAvgField)
        [avgVolume, ~, ~, ~] = reshapeSoAToVolume(allData, metricAvgField);
        avgData = double(avgVolume);
        if state.logScale && all(avgData(isfinite(avgData)) > 0)
            avgData = log10(avgData);
        end

        cla(ax2);
        pcolor(ax2, pGrid, rGrid, avgData);
        shading(ax2, state.interpolation);
        colormap(ax2, cmap);
        colorbar(ax2, "Color", "w");
        ax2.Title.String = sprintf("Average %s", strrep(state.primaryMetric, "_", "\_"));
        ax2.XLabel.String = "Period (nm)";
        ax2.YLabel.String = "Radius (nm)";
        if state.showGrid
            grid(ax2, "on");
        end
    end

    % 3. Spectral profile at selected point
    updateSpectrum(src, struct("p", state.selectedPoint.p, "r", state.selectedPoint.r), fig);

    % 4. Lambda slice (convert stokes shift to wavelength)
    wavelength = state.lambdaLaser / (1 - state.lambdaLaser * state.currentSliceStokes * 1e-7);
    updateSlice(src, struct("wavelength", wavelength, "stokesShift", state.currentSliceStokes), fig);

    % 5. 3D volume visualization
    update3DVolume(src, struct(), fig);

    sendEventToHTMLSource(src, "VisualizationUpdated", struct( ...
        "metric", state.primaryMetric, ...
        "success", true));
end

function updateSlice(~, eventData, fig)
% Update wavelength slice visualization (using SoA format)
    state = fig.UserData.state;

    if ~state.predictionsLoaded
        return;
    end

    wavelength = eventData.wavelength; % nm
    if isfield(eventData, "stokesShift")
        stokesShift = eventData.stokesShift;
        state.currentSliceStokes = stokesShift;
    else
        % Calculate stokes shift from wavelength if not provided
        stokesShift = (1/state.lambdaLaser - 1/wavelength) * 1e7;
        state.currentSliceStokes = stokesShift;
    end
    fig.UserData.state = state;

    allData = state.allData;
    metricField = matlab.lang.makeValidName(state.primaryMetric);

    % Convert SoA to volume
    [metricVolume, pGrid, rGrid, lambdaGrid] = reshapeSoAToVolume(allData, metricField);

    [~, lamIdx] = min(abs(lambdaGrid - wavelength));
    actualWavelength = lambdaGrid(lamIdx);
    actualStokes = (1/state.lambdaLaser - 1/actualWavelength) * 1e7;
    sliceData = double(metricVolume(:, :, lamIdx));

    if state.logScale && all(sliceData(isfinite(sliceData)) > 0)
        sliceData = log10(sliceData);
    end

    try
        cmap = loadColormap("AuroraAustralis.txt", 256);
        if state.colormapInverted
            cmap = flipud(cmap);
        end
    catch
        cmap = parula(256);
    end

    ax4 = fig.UserData.axes.slice;
    cla(ax4);
    pcolor(ax4, pGrid, rGrid, sliceData);
    shading(ax4, state.interpolation);
    colormap(ax4, cmap);
    colorbar(ax4, "Color", "w");
    ax4.Title.String = sprintf("%s at Δν = %.0f cm⁻¹ (λ = %.1f nm)", strrep(state.primaryMetric, "_", "\_"), actualStokes, actualWavelength);
    ax4.Title.Color = "w";
    ax4.Title.FontSize = 14;
    ax4.XLabel.String = "Period (nm)";
    ax4.YLabel.String = "Radius (nm)";
    if state.showGrid
        grid(ax4, "on");
    end
end

function updateSpectrum(src, eventData, fig)
% Update spectral profile at selected (p, r) point (using SoA format)
    state = fig.UserData.state;

    if ~state.predictionsLoaded
        return;
    end

    pVal = eventData.p; % nm
    rVal = eventData.r; % nm
    state.selectedPoint = struct("p", pVal, "r", rVal);
    fig.UserData.state = state;

    allData = state.allData;
    metricField = matlab.lang.makeValidName(state.primaryMetric);

    % Find the geometry row in SoA that matches the selected (p, r) (data already in nm)
    period_nm = allData.period;
    radius_nm = allData.radius;
    
    % Find nearest geometry
    distances = sqrt((period_nm - pVal).^2 + (radius_nm - rVal).^2);
    [~, rowIdx] = min(distances);
    
    actualP = period_nm(rowIdx);
    actualR = radius_nm(rowIdx);
    
    % Extract spectrum for this geometry (data already in nm)
    spectrum = allData.(metricField)(rowIdx, :);
    lambdas = allData.lambda(rowIdx, :);

    ax3 = fig.UserData.axes.spectrum;
    cla(ax3);
    plot(ax3, lambdas, spectrum, "LineWidth", 2, "Color", [0.3 0.7 1]);
    ax3.Title.String = sprintf("Spectral Profile: p = %.0f nm, r = %.0f nm", actualP, actualR);
    ax3.Title.Color = "w";
    ax3.Title.FontSize = 14;
    ax3.XLabel.String = "Wavelength (nm)";
    ax3.YLabel.String = strrep(state.primaryMetric, "_", "\_");
    if state.showGrid
        grid(ax3, "on");
    end

    % Mark laser wavelength
    hold(ax3, "on");
    xline(ax3, state.lambdaLaser, "--r", "LineWidth", 1.5, "Label", sprintf("λ₀ = %.0f nm", state.lambdaLaser));
    hold(ax3, "off");

    if ~isempty(src)
        sendEventToHTMLSource(src, "SpectrumUpdated", struct( ...
            "p", actualP, ...
            "r", actualR));
    end
end

function update3DVolume(~, ~, fig)
% Update 3D volume visualization using volshow (using SoA format)
    state = fig.UserData.state;

    if ~state.predictionsLoaded
        return;
    end

    allData = state.allData;
    metricField = matlab.lang.makeValidName(state.primaryMetric);

    if ~isfield(allData, metricField)
        return;
    end

    % Convert SoA to volume (data already in nm)
    [volData, xData, yData, zData] = reshapeSoAToVolume(allData, metricField);
    volData = double(volData);

    % Normalize volume
    volMin = min(volData(:), [], "omitnan");
    volMax = max(volData(:), [], "omitnan");
    volRange = volMax - volMin;
    if volRange > 0
        volNorm = (volData - volMin) / volRange;
    else
        volNorm = zeros(size(volData));
    end
    volNorm(~isfinite(volNorm)) = 0;

    % Load colormap
    try
        cmap = loadColormap("AuroraAustralis.txt", 4095);
        if state.colormapInverted
            cmap = flipud(cmap);
        end
    catch
        cmap = parula(4095);
    end

    % Create alpha map
    epsilon = 1e-4;
    alphaMap = log(linspace(epsilon, 1, 4095));
    alphaMap = 1 - alphaMap / min(alphaMap);

    % Compute transformation for proper scaling
    lx = max(xData(:)) - min(xData(:));
    ly = max(yData(:)) - min(yData(:));
    lz = min(zData(:)) - max(zData(:)); % Inverted for proper orientation
    sx = lx / numel(xData);
    sy = ly / numel(yData);
    sz = lz / numel(zData);
    A = [sx 0 0 0; 0 sy 0 0; 0 0 sz 0; 0 0 0 1];
    tform = affinetform3d(A);

    % Get viewer3d object and clear existing volume
    viewer = fig.UserData.viewer3d;
    if ~isempty(fig.UserData.volshow) && isvalid(fig.UserData.volshow)
        delete(fig.UserData.volshow);
    end

    % Create volshow in the viewer3d
    hVol = volshow(volNorm * 4095, ...
        "Parent", viewer, ...
        "DisplayRangeMode", "12-bit", ...
        "RenderingStyle", "GradientOpacity", ...
        "GradientOpacityValue", 0.2, ...
        "Colormap", cmap, ...
        "Alphamap", alphaMap, ...
        "Transformation", tform, ...
        "Interpolation", "bilinear");

    % Configure viewer
    viewer.Lighting = "on";
    viewer.LightPositionMode = "target-right";
    viewer.Box = "off";
    viewer.ScaleBar = "on";
    viewer.ScaleBarStyle = "measure";
    viewer.BackgroundColor = "black";
    viewer.BackgroundGradient = "off";
    viewer.SpatialUnits = "nm";
    viewer.RenderingQuality = "high";
    viewer.Toolbar = "on";
    viewer.OrientationAxes = "on";

    % Add axis annotations
    offset = [sx sy sz] / 2;
    xAxis = images.ui.graphics.roi.Line(Position=[0 0 0; lx 0 0] + [offset; offset]);
    xAxis.Label = "Period (p)";
    yAxis = images.ui.graphics.roi.Line(Position=[0 0 0; 0 ly 0] + [offset; offset]);
    yAxis.Label = "Radius (r)";
    zAxis = images.ui.graphics.roi.Line(Position=[0 0 0; 0 0 lz] + [offset; offset]);
    zAxis.Label = "Wavelength (λ)";

    % Add corner point labels
    pOrig = images.ui.graphics.roi.Point(Position=[0 0 0] + offset);
    pOrig.Label = sprintf("p=%.0f nm\nr=%.0f nm\nλ=%.0f nm", min(xData(:)), min(yData(:)), min(zData(:)));
    pX = images.ui.graphics.roi.Point(Position=[lx 0 0] + offset);
    pX.Label = sprintf("p=%.0f nm", max(xData(:)));
    pY = images.ui.graphics.roi.Point(Position=[0 ly 0] + offset);
    pY.Label = sprintf("r=%.0f nm", max(yData(:)));
    pZ = images.ui.graphics.roi.Point(Position=[0 0 lz] + offset);
    pZ.Label = sprintf("λ=%.0f nm", max(zData(:)));

    viewer.Annotations = [xAxis yAxis zAxis pOrig pX pY pZ];

    % Set camera position
    szVol = size(volNorm);
    center = [szVol(2) szVol(1) -szVol(3)] / 2 + 0.5;
    dist = sqrt(szVol(1)^2 + szVol(2)^2 + szVol(3)^2);
    viewer.CameraPosition = center + [cos(3*pi/4) sin(3*pi/4) 1] * dist;
    viewer.CameraTarget = center;
    viewer.CameraUpVector = [0 1 0];

    fig.UserData.volshow = hVol;
end

function updateConfig(src, eventData, fig)
% Update configuration from HTML interface
    state = fig.UserData.state;

    fields = fieldnames(eventData);
    for i = 1:numel(fields)
        fname = fields{i};
        if isfield(state, fname)
            state.(fname) = eventData.(fname);
        end
    end

    fig.UserData.state = state;
    sendEventToHTMLSource(src, "ConfigUpdated", struct("success", true));
end

function browseFile(src, eventData, fig)
% Open file browser dialog
    fileType = eventData.type;

    switch fileType
        case "model"
            [file, path] = uigetfile({"*.mat", "MAT-files (*.mat)"}, ...
                "Select Model File", fig.UserData.state.workDir);
            if file ~= 0
                fig.UserData.state.modelFile = fullfile(path, file);
                sendEventToHTMLSource(src, "FileSelected", struct( ...
                    "type", "model", "path", fullfile(path, file)));
            end
        case "predictions"
            [file, path] = uigetfile({"*.mat", "MAT-files (*.mat)"}, ...
                "Select Predictions File", fig.UserData.state.workDir);
            if file ~= 0
                fig.UserData.state.predictionFile = fullfile(path, file);
                sendEventToHTMLSource(src, "FileSelected", struct( ...
                    "type", "predictions", "path", fullfile(path, file)));
            end
        case "ri"
            [file, path] = uigetfile({"*.csv", "CSV-files (*.csv)"}, ...
                "Select Refractive Index File", fig.UserData.state.workDir);
            if file ~= 0
                fig.UserData.state.riFile = fullfile(path, file);
                sendEventToHTMLSource(src, "FileSelected", struct( ...
                    "type", "ri", "path", fullfile(path, file)));
            end
        case "workDir"
            folder = uigetdir(fig.UserData.state.workDir, "Select Working Directory");
            if folder ~= 0
                fig.UserData.state.workDir = folder;
                sendEventToHTMLSource(src, "FileSelected", struct( ...
                    "type", "workDir", "path", folder));
            end
        case "analyteSpectrum"
            [file, path] = uigetfile({"*.dat;*.txt;*.csv", "Spectrum files (*.dat, *.txt, *.csv)"}, ...
                "Select Analyte Raman Spectrum File", fig.UserData.state.workDir);
            if file ~= 0
                fig.UserData.state.analyteSpectrumFile = fullfile(path, file);
                sendEventToHTMLSource(src, "FileSelected", struct( ...
                    "type", "analyteSpectrum", "path", fullfile(path, file)));
            end
    end
end

function loadAnalyteSpectrum(src, eventData, fig)
% Load analyte Raman spectrum for weighted metrics
    state = fig.UserData.state;

    if isfield(eventData, "filePath") && ~isempty(eventData.filePath)
        spectrumFile = string(eventData.filePath);
    else
        spectrumFile = state.analyteSpectrumFile;
    end

    if isempty(spectrumFile) || ~isfile(spectrumFile)
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Analyte spectrum file not found: %s", spectrumFile)));
        return;
    end

    sendEventToHTMLSource(src, "Status", struct( ...
        "message", "Loading analyte Raman spectrum...", "progress", 10));

    try
        analyteSpectrum = loadAndNormalizeAnalyteSpectrum(spectrumFile);
        if isempty(analyteSpectrum) || ~isfield(analyteSpectrum, "shift_cm")
            error("Failed to parse spectrum file.");
        end

        fig.UserData.state.analyteSpectrum = analyteSpectrum;
        fig.UserData.state.analyteSpectrumFile = spectrumFile;
        fig.UserData.state.useAnalyteWeighting = true;

        sendEventToHTMLSource(src, "Status", struct( ...
            "message", "Analyte spectrum loaded successfully!", "progress", 100));
        sendEventToHTMLSource(src, "AnalyteSpectrumLoaded", struct( ...
            "filePath", spectrumFile, ...
            "shiftRange", [min(analyteSpectrum.shift_cm), max(analyteSpectrum.shift_cm)]));
    catch ME
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Failed to load analyte spectrum: %s", ME.message)));
    end
end

function exportGraphics(src, eventData, fig)
% Export current visualization to file
    state = fig.UserData.state;

    if ~state.predictionsLoaded
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", "No predictions to export."));
        return;
    end

    exportType = eventData.type;
    format = eventData.format;

    [file, path] = uiputfile({ ...
        "*.png", "PNG Image (*.png)"; ...
        "*.pdf", "PDF Document (*.pdf)"; ...
        "*.svg", "SVG Vector (*.svg)"; ...
        "*.fig", "MATLAB Figure (*.fig)"}, ...
        "Export Graphics", fullfile(state.workDir, sprintf("sers_%s.%s", exportType, format)));

    if file == 0
        return;
    end

    filePath = fullfile(path, file);

    try
        switch exportType
            case "laser"
                ax = fig.UserData.axes.laser;
            case "avg"
                ax = fig.UserData.axes.avg;
            case "spectrum"
                ax = fig.UserData.axes.spectrum;
            case "slice"
                ax = fig.UserData.axes.slice;
            case "all"
                % Export entire figure
                exportgraphics(fig.UserData.visGrid.Parent, filePath, "Resolution", 300);
                sendEventToHTMLSource(src, "ExportComplete", struct( ...
                    "path", filePath));
                return;
        end

        exportgraphics(ax, filePath, "Resolution", 300);
        sendEventToHTMLSource(src, "ExportComplete", struct("path", filePath));
    catch ME
        sendEventToHTMLSource(src, "Error", struct( ...
            "message", sprintf("Export failed: %s", ME.message)));
    end
end

function sendStateToHTML(h, state)
% Send current state to HTML interface
    stateData = struct();
    stateData.workDir = state.workDir;
    stateData.riFile = state.riFile;
    stateData.modelFile = state.modelFile;
    stateData.predictionFile = state.predictionFile;
    stateData.availableMetrics = state.availableMetrics;
    stateData.selectedMetrics = state.selectedMetrics;
    stateData.primaryMetric = state.primaryMetric;
    stateData.resolution = state.resolution;
    stateData.lambdaLaser = state.lambdaLaser;
    stateData.pLimits = state.pLimits;
    stateData.rLimits = state.rLimits;
    stateData.stokesShiftLimits = state.stokesShiftLimits;
    stateData.stokesShiftResolution = state.stokesShiftResolution;
    stateData.analyteSpectrumFile = state.analyteSpectrumFile;
    stateData.useAnalyteWeighting = state.useAnalyteWeighting;
    stateData.colormapInverted = state.colormapInverted;
    stateData.logScale = state.logScale;
    stateData.showGrid = state.showGrid;
    stateData.interpolation = state.interpolation;
    stateData.currentSliceStokes = state.currentSliceStokes;
    stateData.selectedPoint = state.selectedPoint;
    stateData.modelLoaded = state.modelLoaded;
    stateData.predictionsLoaded = state.predictionsLoaded;

    sendEventToHTMLSource(h, "StateUpdate", stateData);
end

function riLoaded = loadRefractiveIndexData(fig)
% Load refractive index data from various possible locations
    state = fig.UserData.state;
    riLoaded = false;

    % List of potential locations for McPeak.csv
    possiblePaths = {
        fullfile(state.workDir, state.riCsvFile), ...
        fullfile(fileparts(mfilename("fullpath")), state.riCsvFile), ...
        fullfile(pwd, state.riCsvFile), ...
        state.riCsvFile ...
    };

    for i = 1:numel(possiblePaths)
        riFile = possiblePaths{i};
        if isfile(riFile)
            try
                fig.UserData.state.ri = load_gold_refractive_index(riFile, "WavelengthUnit", "um");
                riLoaded = true;
                return;
            catch
                % Try next location
            end
        end
    end
end
