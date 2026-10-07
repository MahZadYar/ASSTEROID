% run_prediction_vis  Generate dense predictions and visualise SERS metrics.
%
% This script loads a trained model, produces dense predictions across the
% configured (p,r,lambda) grid, saves the prediction volume, and provides a
% couple of quick-look visualisations (spectral average map and a 3-D
% volume render).

%% Configuration
workDir = pwd;
riCsv = fullfile(pwd, "McPeak.csv");
outputModelFile = fullfile(pwd, "sers_dnn_model_cylinder_all.mat");
outputPredictionFile = fullfile(pwd, "sers_dnn_dense_predictions_cylinder_all.mat");

metricsToTrain = {'Absorptance','M_vol','M_surf','EF_vol','EF_surf'}; % primary metric must match the trained model

doDensePrediction = true; % set false to reuse an existing prediction file
stokesShiftSamples = linspace(100, 3500, 3400); % cm^-1 window for spectral averaging
lambdaLaser = 0.785; % um
% lambdaSamples = lambdaLaser * 1e-6 + stokesShiftSamples * 1e-2; % um
lambdaSamples = linspace(0.785, 1.100, 321); % um
pSamples = linspace(0.650, 0.950, 301);   % um
rSamples = linspace(0.050, 0.500, 451);   % um




%% Normalise metric selection
availableTargets = {'Absorptance','M_vol','M_surf','EF_vol','EF_surf'};
aliasKeys = {'absorptance','abs','m_vol','mvol','m_surf','msurf','ef_vol','efvol','ef_surf','efsrf'};
aliasValues = {'Absorptance','Absorptance','M_vol','M_vol','M_surf','M_surf','EF_vol','EF_vol','EF_surf','EF_surf'};
aliasMap = containers.Map(aliasKeys, aliasValues);
normalizedTargets = cellfun(@(s) lower(regexprep(s, '\s+', '')), metricsToTrain, 'UniformOutput', false);
metricsCanonical = cell(size(normalizedTargets));
for tIdx = 1:numel(normalizedTargets)
    key = regexprep(normalizedTargets{tIdx}, '[^a-z0-9_]', '');
    if isKey(aliasMap, key)
        metricsCanonical{tIdx} = aliasMap(key);
    else
        matchIdx = find(strcmpi(key, availableTargets), 1);
        if isempty(matchIdx)
            error('run_prediction_vis:UnknownMetric', ...
                'Unsupported metric "%s". Valid options: %s', metricsToTrain{tIdx}, strjoin(availableTargets, ', '));
        end
        metricsCanonical{tIdx} = availableTargets{matchIdx};
    end
end
metricsToTrain = unique(metricsCanonical, 'stable');
if isempty(metricsToTrain)
    error('run_prediction_vis:NoMetrics', 'metricsToTrain must contain at least one metric.');
end
numMetrics = numel(metricsToTrain);
primaryMetric = metricsToTrain{1};
fprintf('Configured metrics (%d): %s\n', numMetrics, strjoin(metricsToTrain, ', '));

%% Load resources
if ~isfile(outputModelFile)
    error('run_prediction_vis:MissingModel', 'Trained model not found: %s', outputModelFile);
end
modelStruct = load(outputModelFile, 'model');
if ~isfield(modelStruct, 'model')
    error('run_prediction_vis:InvalidModelFile', 'File %s does not contain variable ''model''.', outputModelFile);
end
model = modelStruct.model;

ri = load_gold_refractive_index(riCsv, 'WavelengthUnit', 'um');

%% Generate or load dense predictions
if doDensePrediction
    fprintf('Generating dense predictions for configured metrics (primary: %s)...\n', primaryMetric);
    predictions = predict_dense_spectrum(model, pSamples, rSamples, lambdaSamples, ri);
    save(outputPredictionFile, 'predictions', 'pSamples', 'rSamples', 'lambdaSamples');
    fprintf('Saved dense prediction volumes to %s\n', outputPredictionFile);
end

if ~exist('predictions', 'var')
    if ~isfile(outputPredictionFile)
        error('run_prediction_vis:MissingPredictions', ...
            'Dense predictions file not found: %s. Set doDensePrediction=true to regenerate.', outputPredictionFile);
    end
    loadedPred = load(outputPredictionFile, 'predictions', 'pSamples', 'rSamples', 'lambdaSamples');
    if ~isfield(loadedPred, 'predictions')
        error('run_prediction_vis:InvalidPredictionFile', ...
            'File %s does not contain variable ''predictions''.', outputPredictionFile);
    end
    predictions = loadedPred.predictions;
    if isfield(loadedPred, 'pSamples'), pSamples = loadedPred.pSamples; end
    if isfield(loadedPred, 'rSamples'), rSamples = loadedPred.rSamples; end
    if isfield(loadedPred, 'lambdaSamples'), lambdaSamples = loadedPred.lambdaSamples; end
    fprintf('Loaded dense predictions from %s\n', outputPredictionFile);
end

fprintf('Dense prediction workflow complete.');

%% Per-metric visualisation
exportVideo = false;
for metricIdx = 1:numMetrics
    metricName = metricsToTrain{metricIdx};
    metricField = matlab.lang.makeValidName(metricName);
    metricAvgField = matlab.lang.makeValidName([metricName, '_avg']);
    metricLabel = strrep(metricName, '_', '\_');
    fprintf('\n\nProcessing metric %s (%d/%d)\n', metricName, metricIdx, numMetrics);

    %% Spectral average map
    if isfield(predictions, metricAvgField) && ...
            isfield(predictions, 'PGrid') && isfield(predictions, 'RGrid')
        avgMetricGrid = double(predictions.(metricAvgField));

        figure;
        hPcolor = pcolor(predictions.PGrid * 1e3, predictions.RGrid * 1e3, avgMetricGrid);
        set(hPcolor, 'EdgeColor', 'none');
        set(gca, 'YDir', 'normal');
        xlabel('p (nm)');
        ylabel('r (nm)');
        title(sprintf('Average %s across \lambda', metricLabel));
        colorbar;
    else
        warning('run_prediction_vis:AvgFieldMissing', ...
            'Predictions do not contain averaged field %s or the corresponding grids.', metricAvgField);
    end

    %% 3-D volume visualisation
    if ~isfield(predictions, metricField)
        warning('run_prediction_vis:MetricFieldMissing', ...
            'Predictions do not contain metric field %s. Skipping volume visualisation.', metricField);
        continue;
    end

    fprintf('Visualising metric %s with volshow...\n', metricName);

    volData = double(predictions.(metricField));
    xData = predictions.PGrid * 1e3; % nm
    yData = predictions.RGrid * 1e3; % nm
    zData = predictions.Lambda * 1e3; % nm

    volMin = min(volData(:), [], 'omitnan');
    volMax = max(volData(:), [], 'omitnan');
    volRange = volMax - volMin;
    if volRange > 0
        volNorm = (volData - volMin) / volRange;
    else
        volNorm = zeros(size(volData));
    end
    volNorm(~isfinite(volNorm)) = 0;

    cmap = loadColormap('AuroraAustralis.txt', 4095);
    cmap = flipud(cmap);
    colormap(cmap);
    epsilon = 1e-4;
    alphaMap = log(linspace(epsilon, 1, 4095));
    alphaMap = 1-alphaMap/min(alphaMap);

    lx = (max(xData(:))-min(xData(:)));
    ly = (max(yData(:))-min(yData(:)));
    lz = (min(zData(:))-max(zData(:)));
    sx = lx/size(xData,2);
    sy= ly/size(yData,2);
    sz = lz/size(zData,2);
    sMax = max([sx, sy, sz]);
    A = [sx 0 0 0; 0 sy 0 0; 0 0 sz 0; 0 0 0 1];
    tform = affinetform3d(A);

    h = volshow(volNorm*4095, ...
        'DisplayRangeMode', '12-bit', ...
        'RenderingStyle', 'GradientOpacity', ...
        'GradientOpacityValue', 0.2, ...
        'Colormap', cmap, ...
        'Alphamap', alphaMap, ...
        'Transformation', tform, ...
        'Interpolation', 'bilinear' ...
        );

    viewer = h.Parent;
    hFig = viewer.Parent;
    viewer.Lighting = 'on';
    viewer.LightPositionMode = 'target-right';
    viewer.Box = 'off';
    viewer.ScaleBar = 'on';
    viewer.ScaleBarStyle = 'measure';
    % viewer.DisplayInfo = 'on';
    viewer.BackgroundColor = 'black';
    viewer.BackgroundGradient = 'off';
    viewer.SpatialUnits = 'nm';
    viewer.RenderingQuality = 'high';
    viewer.Toolbar = 'off';
    viewer.OrientationAxes = 'off';

    offset = [sx sy sz]/2;
    xAxis = images.ui.graphics.roi.Line(Position=[0 0 0; lx 0 0] + [offset ; offset]);
    xAxis.Label = 'Lattice Period';
    yAxis = images.ui.graphics.roi.Line(Position=[0 0 0; 0 ly 0] + [offset ; offset]);
    yAxis.Label = 'Particle Radius';
    zAxis = images.ui.graphics.roi.Line(Position=[0 0 0; 0 0 lz] + [offset ; offset]);
    zAxis.Label = 'Wavelength';
    pOrig = images.ui.graphics.roi.Point(Position=[0 0 0] + offset);
    pOrig.Label = sprintf('p = %d nm\nr = %d nm\nλ = %d nm', min(xData(:)), min(yData(:)), min(zData(:)));
    pX = images.ui.graphics.roi.Point(Position=[lx 0 0] + offset);
    pX.Label = sprintf('p = %d nm', max(xData(:)));
    pY = images.ui.graphics.roi.Point(Position=[0 ly 0] + offset);
    pY.Label = sprintf('r = %d nm', max(yData(:)));
    pZ = images.ui.graphics.roi.Point(Position=[0 0 lz] + offset);
    pZ.Label = sprintf('λ = %d nm', max(zData(:)));
    viewer.Annotations = [xAxis yAxis zAxis pOrig pX pY pZ];

    szVol = size(volNorm);
    center = [szVol(2) szVol(1) -szVol(3)]/2 + 0.5;
    dist = sqrt(szVol(1)^2 + szVol(2)^2 + szVol(3)^2);
    viewer.CameraPosition = center + ([cos(3*pi/4) sin(3*pi/4) 1]*dist);
    viewer.CameraTarget = center;
    viewer.CameraUpVector = [0 1 0];

    if exportVideo
        numFrames = 360;
        vec = linspace(0,2*pi,numFrames)' + 3*pi/4;
        videoSize = [1080 1080];
        hFig.Position = [10 10 videoSize(1) videoSize(2)];
        videoFile = fullfile(workDir, sprintf('dense_prediction_3Dvis_%s', metricField));
        v = VideoWriter(videoFile, 'Archival');
        v.FrameRate = 30;
        v.MJ2BitDepth = 12;
        % v.Quality = 100;
        % v.CompressionRatio = 1;

        open(v);
        for fIdx = 1:numFrames
            angle = vec(fIdx);
            viewer.CameraPosition = center + ([cos(angle) sin(angle) 1]*dist);
            frame = getframe(hFig);
            writeVideo(v, frame);
        end

        close(v);
        fprintf('Exported rotation video to %s\n', videoFile);
    end
end