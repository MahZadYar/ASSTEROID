function perfReport = computeSurrogateEvaluationMetrics(model, dataset, dbOptima, options)
% COMPUTESTURROGATEEVALUATIONMETRICS Comprehensive three-tier surrogate evaluation.
%
%   perfReport = computeSurrogateEvaluationMetrics(model, dataset, dbOptima)
%   computes statistical performance metrics across three evaluation tiers:
%     1. Tier 1: Global Empirical (Biased) Holdout Test Split
%     2. Tier 2: Global Unbiased Expectation via Inverse Density Weighting (IDW)
%     3. Tier 3: Region of Interest (RoI) Localized Accuracy around Modal Optima
%
%   Arguments:
%     model    - Struct containing trained surrogate network (net, targetNames,
%                targetTransform, featureSchema, etc.) or empty if dataset contains YPred.
%     dataset  - Struct containing test features and targets:
%                XTest: [N x D] (inputs: p, r, lambda, ...)
%                YTest: [N x K] (physical ground truth targets)
%                YPred: [N x K] (optional: precomputed physical predictions)
%                targetNames: [1 x K] string / cellstr array
%     dbOptima - (Optional) struct containing validated optima from db.Optima
%                (period, radius, basinTag, optimizedMetric, metricValue).
%
%   Options (Name-Value):
%     KNearestNeighbors (1,1) double = 15
%     RoiRadiusNm       (1,1) double = 20
%     Verbose           (1,1) logical = true
%
%   Returns:
%     perfReport - Struct containing:
%       .globalBiased    - table of Tier 1 holdout test metrics
%       .globalUnbiased  - table of Tier 2 IDW unbiased metrics
%       .roiOptima       - table of Tier 3 per-mode optima metrics
%       .roiCombined     - table of Tier 3 pooled optima basin metrics
%       .latexSummary    - string containing journal-ready LaTeX table
%       .summaryText     - formatted ASCII summary table
%       .raw             - raw evaluation struct with weights and intermediate vectors
%
%   See also: train_surrogate_dnn, prepare_training_dataset, denormalizeModelTargets

arguments
    model               = []
    dataset             = struct()
    dbOptima            = []
    options.KNearestNeighbors (1,1) double {mustBePositive} = 15
    options.RoiRadiusNm       (1,1) double {mustBePositive} = 20
    options.Verbose           (1,1) logical                 = true
end

if isempty(dataset) || ~isstruct(dataset)
    error("computeSurrogateEvaluationMetrics:InvalidDataset", ...
        "A valid dataset struct containing XTest and YTest must be provided.");
end

%% 1. Extract Ground Truth and Generate Predictions
if isfield(dataset, "YTest")
    YTrue = double(dataset.YTest);
elseif isfield(dataset, "YTrue")
    YTrue = double(dataset.YTrue);
else
    error("computeSurrogateEvaluationMetrics:MissingYTest", "dataset missing YTest field.");
end

if isfield(dataset, "XTest")
    XTest = double(dataset.XTest);
else
    XTest = [];
end

% Resolve target names
if isfield(dataset, "targetNames") && ~isempty(dataset.targetNames)
    targetNames = string(dataset.targetNames);
elseif isstruct(model) && isfield(model, "targetNames") && ~isempty(model.targetNames)
    targetNames = string(model.targetNames);
else
    targetNames = "Target_" + string(1:size(YTrue, 2));
end
numTargets = size(YTrue, 2);

% Extract or evaluate predictions
if isfield(dataset, "YPred") && ~isempty(dataset.YPred)
    YPred = double(dataset.YPred);
elseif isstruct(model) && isfield(model, "net") && ~isempty(model.net) && ~isempty(XTest)
    if options.Verbose
        fprintf("[computeSurrogateEvaluationMetrics] Running surrogate inference on %d test samples...\n", size(XTest, 1));
    end
    % Forward features
    if isfield(model, "normalize") && isa(model.normalize, "function_handle")
        XNorm = model.normalize(XTest);
    elseif isfield(dataset, "normalize") && isa(dataset.normalize, "function_handle")
        XNorm = dataset.normalize(XTest);
    else
        XNorm = XTest;
    end
    
    ZPred = predict(model.net, XNorm);
    if isa(ZPred, "dlarray"), ZPred = extractdata(ZPred); end
    ZPred = double(ZPred);
    
    if isfield(model, "denormalize") && isa(model.denormalize, "function_handle")
        YPred = model.denormalize(ZPred);
    elseif isfield(dataset, "denormalize") && isa(dataset.denormalize, "function_handle")
        YPred = dataset.denormalize(ZPred);
    else
        YPred = ZPred;
    end
else
    error("computeSurrogateEvaluationMetrics:CannotPredict", ...
        "Neither precomputed YPred nor valid model.net + XTest were provided.");
end

%% 2. Identify Target Types (Linear vs Logarithmic)
logCandidates = ["ef_vol", "ef_surf", "m_vol", "m_surf", "intw_vol", "intw_t"];
targetLogMask = false(1, numTargets);
if isstruct(model) && isfield(model, "targetTransform") && isstruct(model.targetTransform) ...
        && isfield(model.targetTransform, "LogMask") && ~isempty(model.targetTransform.LogMask)
    targetLogMask = logical(model.targetTransform.LogMask);
elseif isfield(dataset, "targetLogMask") && ~isempty(dataset.targetLogMask)
    targetLogMask = logical(dataset.targetLogMask);
else
    for k = 1:numTargets
        targetLogMask(k) = any(strcmpi(targetNames(k), logCandidates));
    end
end
if numel(targetLogMask) < numTargets
    targetLogMask = [targetLogMask, false(1, numTargets - numel(targetLogMask))];
end

%% 3. Tier 1: Global Empirical (Biased) Holdout Test Metrics
N_test = size(YTrue, 1);
maeBiased     = zeros(numTargets, 1);
rmseBiased    = zeros(numTargets, 1);
nrmseBiased   = zeros(numTargets, 1);
nrmsleBiased  = zeros(numTargets, 1);
r2Biased      = zeros(numTargets, 1);
maxErrBiased  = zeros(numTargets, 1);

for k = 1:numTargets
    yT = YTrue(:, k);
    yP = YPred(:, k);
    diff_k = yP - yT;
    
    maeBiased(k)  = mean(abs(diff_k), 'omitnan');
    rmse_k        = sqrt(mean(diff_k.^2, 'omitnan'));
    rmseBiased(k) = rmse_k;
    
    yRange = max(yT, [], 'omitnan') - min(yT, [], 'omitnan');
    nrmseBiased(k) = (rmse_k / max(yRange, eps)) * 100;
    
    % Decadic log metrics (for near-field quantities)
    logT = log10(max(yT, 0) + 1);
    logP = log10(max(yP, 0) + 1);
    rmsle_k = sqrt(mean((logP - logT).^2, 'omitnan'));
    logRange = max(logT, [], 'omitnan') - min(logT, [], 'omitnan');
    nrmsleBiased(k) = (rmsle_k / max(logRange, eps)) * 100;
    
    % R^2
    ssTot = sum((yT - mean(yT, 'omitnan')).^2, 'omitnan');
    ssRes = sum(diff_k.^2, 'omitnan');
    r2Biased(k) = 1 - ssRes / max(ssTot, eps);
    
    maxErrBiased(k) = max(abs(diff_k), [], 'omitnan');
end

tblBiased = table(targetNames(:), maeBiased, rmseBiased, nrmseBiased, nrmsleBiased, r2Biased, maxErrBiased, ...
    'VariableNames', {'Target', 'MAE', 'RMSE', 'NRMSE_Pct', 'N_RMSLE_Pct', 'R2', 'MaxAbsErr'});

%% 4. Tier 2: Global Unbiased via Inverse Density Weighting (IDW)
idwWeights = ones(N_test, 1) / N_test;
hasCoords = false;

if ~isempty(XTest) && size(XTest, 2) >= 2
    % Columns 1 and 2 are period and radius (in micrometers or nanometers)
    pVals = XTest(:, 1);
    rVals = XTest(:, 2);
    
    % Normalize coordinates to unit square for isotropic distance metric
    pMin = min(pVals); pMax = max(pVals);
    rMin = min(rVals); rMax = max(rVals);
    pNorm = (pVals - pMin) / max(pMax - pMin, eps);
    rNorm = (rVals - rMin) / max(rMax - rMin, eps);
    coords = [pNorm, rNorm];
    
    % Compute k-nearest-neighbor distances
    kNN = min(options.KNearestNeighbors, max(2, N_test - 1));
    try
        % Fast pdist2 for sample spacing
        distMat = pdist2(coords, coords);
        distSorted = sort(distMat, 2);
        dk = distSorted(:, kNN + 1);
        
        % Local density in 2D normalized space
        density = kNN ./ (pi * max(dk, 1e-4).^2);
        
        % Importance weights w_i proportional to 1 / density
        rawWeights = 1 ./ max(density, 1e-9);
        idwWeights = rawWeights / sum(rawWeights);
        hasCoords = true;
    catch ME_idw
        if options.Verbose
            warning("computeSurrogateEvaluationMetrics:IdwFailed", ...
                "IDW density estimation failed (%s); using uniform weights.", ME_idw.message);
        end
    end
end

maeIdw    = zeros(numTargets, 1);
rmseIdw   = zeros(numTargets, 1);
nrmseIdw  = zeros(numTargets, 1);
nrmsleIdw = zeros(numTargets, 1);
r2Idw     = zeros(numTargets, 1);

for k = 1:numTargets
    yT = YTrue(:, k);
    yP = YPred(:, k);
    diff_k = yP - yT;
    
    maeIdw(k)  = sum(idwWeights .* abs(diff_k), 'omitnan');
    rmse_k     = sqrt(sum(idwWeights .* (diff_k.^2), 'omitnan'));
    rmseIdw(k) = rmse_k;
    
    yRange = max(yT, [], 'omitnan') - min(yT, [], 'omitnan');
    nrmseIdw(k) = (rmse_k / max(yRange, eps)) * 100;
    
    logT = log10(max(yT, 0) + 1);
    logP = log10(max(yP, 0) + 1);
    rmsle_k = sqrt(sum(idwWeights .* ((logP - logT).^2), 'omitnan'));
    logRange = max(logT, [], 'omitnan') - min(logT, [], 'omitnan');
    nrmsleIdw(k) = (rmsle_k / max(logRange, eps)) * 100;
    
    yMean_w = sum(idwWeights .* yT, 'omitnan');
    ssTot_w = sum(idwWeights .* (yT - yMean_w).^2, 'omitnan');
    ssRes_w = sum(idwWeights .* (diff_k.^2), 'omitnan');
    r2Idw(k) = 1 - ssRes_w / max(ssTot_w, eps);
end

tblUnbiased = table(targetNames(:), maeIdw, rmseIdw, nrmseIdw, nrmsleIdw, r2Idw, ...
    'VariableNames', {'Target', 'IDW_MAE', 'IDW_RMSE', 'IDW_NRMSE_Pct', 'IDW_N_RMSLE_Pct', 'IDW_R2'});

%% 5. Tier 3: Region of Interest (RoI) Around Modal Optima
tblRoiOptima = table();
tblRoiCombined = table();
roiMaskAll = false(N_test, 1);

if ~isempty(dbOptima) && isstruct(dbOptima) && isfield(dbOptima, "period") && ~isempty(dbOptima.period) ...
        && ~isempty(XTest)
    optP = double(dbOptima.period(:));
    optR = double(dbOptima.radius(:));
    nOpt = numel(optP);
    
    if isfield(dbOptima, "basinTag") && ~isempty(dbOptima.basinTag)
        basinTags = string(dbOptima.basinTag(:));
    else
        basinTags = "Optimum_" + string(1:nOpt)';
    end
    
    % Coordinate units check: if XTest is in micrometers (values < 10) and optP is in nm (> 100)
    pTest = XTest(:, 1);
    rTest = XTest(:, 2);
    if max(pTest) < 10 && max(optP) > 100
        optP_testUnits = optP * 1e-3;
        optR_testUnits = optR * 1e-3;
        rRoi_testUnits = options.RoiRadiusNm * 1e-3;
    else
        optP_testUnits = optP;
        optR_testUnits = optR;
        rRoi_testUnits = options.RoiRadiusNm;
    end
    
    roiRows = {};
    for j = 1:nOpt
        distJ = sqrt((pTest - optP_testUnits(j)).^2 + (rTest - optR_testUnits(j)).^2);
        inRoiJ = distJ <= rRoi_testUnits;
        roiMaskAll = roiMaskAll | inRoiJ;
        nPointsJ = nnz(inRoiJ);
        
        if nPointsJ > 0
            for k = 1:numTargets
                yT_roi = YTrue(inRoiJ, k);
                yP_roi = YPred(inRoiJ, k);
                diff_roi = yP_roi - yT_roi;
                
                rmse_roi = sqrt(mean(diff_roi.^2, 'omitnan'));
                yRange = max(yT_roi, [], 'omitnan') - min(yT_roi, [], 'omitnan');
                if yRange < 1e-6
                    % Fall back to global test range if local basin is very tight
                    yRange = max(YTrue(:, k), [], 'omitnan') - min(YTrue(:, k), [], 'omitnan');
                end
                nrmse_roi = (rmse_roi / max(yRange, eps)) * 100;
                
                logT = log10(max(yT_roi, 0) + 1);
                logP = log10(max(yP_roi, 0) + 1);
                rmsle_roi = sqrt(mean((logP - logT).^2, 'omitnan'));
                logRange = max(logT, [], 'omitnan') - min(logT, [], 'omitnan');
                if logRange < 1e-4
                    logRange = max(log10(max(YTrue(:, k), 0) + 1), [], 'omitnan') - min(log10(max(YTrue(:, k), 0) + 1), [], 'omitnan');
                end
                nrmsle_roi = (rmsle_roi / max(logRange, eps)) * 100;
                
                meanRelDev = mean(abs(diff_roi) ./ max(abs(yT_roi), 1e-4), 'omitnan') * 100;
                
                ssTot = sum((yT_roi - mean(yT_roi, 'omitnan')).^2, 'omitnan');
                ssRes = sum(diff_roi.^2, 'omitnan');
                r2_roi = 1 - ssRes / max(ssTot, eps);
                
                roiRows{end+1, 1} = struct( ...
                    'BasinTag', basinTags(j), ...
                    'OptPeriodNm', optP(j), ...
                    'OptRadiusNm', optR(j), ...
                    'NumSamples', nPointsJ, ...
                    'Target', targetNames(k), ...
                    'LocalRMSE', rmse_roi, ...
                    'LocalNRMSE_Pct', nrmse_roi, ...
                    'LocalN_RMSLE_Pct', nrmsle_roi, ...
                    'MeanRelDev_Pct', meanRelDev, ...
                    'LocalR2', r2_roi);
            end
        end
    end
    
    if ~isempty(roiRows)
        tblRoiOptima = struct2table(vertcat(roiRows{:}));
    end
    
    % Combined RoI metrics across all basins
    if any(roiMaskAll)
        combRows = {};
        for k = 1:numTargets
            yT_c = YTrue(roiMaskAll, k);
            yP_c = YPred(roiMaskAll, k);
            diff_c = yP_c - yT_c;
            
            rmse_c = sqrt(mean(diff_c.^2, 'omitnan'));
            yRange = max(YTrue(:, k), [], 'omitnan') - min(YTrue(:, k), [], 'omitnan');
            nrmse_c = (rmse_c / max(yRange, eps)) * 100;
            
            logT = log10(max(yT_c, 0) + 1);
            logP = log10(max(yP_c, 0) + 1);
            rmsle_c = sqrt(mean((logP - logT).^2, 'omitnan'));
            logRange = max(log10(max(YTrue(:, k), 0) + 1), [], 'omitnan') - min(log10(max(YTrue(:, k), 0) + 1), [], 'omitnan');
            nrmsle_c = (rmsle_c / max(logRange, eps)) * 100;
            
            ssTot = sum((yT_c - mean(yT_c, 'omitnan')).^2, 'omitnan');
            ssRes = sum(diff_c.^2, 'omitnan');
            r2_c = 1 - ssRes / max(ssTot, eps);
            meanRel = mean(abs(diff_c) ./ max(abs(yT_c), 1e-4), 'omitnan') * 100;
            
            combRows{end+1, 1} = struct( ...
                'Target', targetNames(k), ...
                'TotalRoiSamples', nnz(roiMaskAll), ...
                'RoI_RMSE', rmse_c, ...
                'RoI_NRMSE_Pct', nrmse_c, ...
                'RoI_N_RMSLE_Pct', nrmsle_c, ...
                'RoI_MeanRelDev_Pct', meanRel, ...
                'RoI_R2', r2_c);
        end
        tblRoiCombined = struct2table(vertcat(combRows{:}));
    end
end

%% 6. Generate Journal-Ready LaTeX Table
latexLines = [
    "\begin{table}[htbp]"
    "  \caption{Surrogate model generalization across the three-tier evaluation framework: Tier 1 (Holdout Test Split), Tier 2 (Unbiased Inverse Density Weighting, IDW), and Tier 3 (Modal Optima Region of Interest, RoI).}"
    "  \label{tab:surrogate-generalization}"
    "  \centering"
    "  \small"
    "  \begin{tabular}{lcccccc}"
    "    \hline"
    "    \textbf{Target Metric} & \textbf{Holdout NRMSE} & \textbf{Holdout N-RMSLE} & \textbf{Holdout $R^2$} & \textbf{IDW NRMSE} & \textbf{IDW $R^2$} & \textbf{RoI NRMSE} \\"
    "     & (\%) & (\%) & & (\%) & & (\%) \\"
    "    \hline"
];

for k = 1:numTargets
    tName = targetNames(k);
    if strcmpi(tName, "Absorptance")
        tLabel = "Absorptance $A_L$";
    elseif strcmpi(tName, "EF_vol")
        tLabel = "Volumetric EF $\text{EF}_V^{\text{cell}}$";
    elseif strcmpi(tName, "EF_surf")
        tLabel = "Surface EF $\text{EF}_S^{\text{cell}}$";
    else
        tLabel = strrep(tName, "_", "\_");
    end
    
    roiValStr = "---";
    if ~isempty(tblRoiCombined) && ismember("RoI_NRMSE_Pct", tblRoiCombined.Properties.VariableNames)
        roiIdx = find(string(tblRoiCombined.Target) == tName, 1);
        if ~isempty(roiIdx)
            roiValStr = sprintf("%.2f\\%%", tblRoiCombined.RoI_NRMSE_Pct(roiIdx));
        end
    end
    
    rowStr = sprintf("    %s & %.2f\\%% & %.2f\\%% & %.4f & %.2f\\%% & %.4f & %s \\\\", ...
        tLabel, nrmseBiased(k), nrmsleBiased(k), r2Biased(k), ...
        nrmseIdw(k), r2Idw(k), roiValStr);
    latexLines(end + 1, 1) = string(rowStr); %#ok<AGROW>
end

latexLines = [
    latexLines
    "    \hline"
    "  \end{tabular}"
    "\end{table}"
];
latexSummary = strjoin(latexLines, newline);

%% 7. Formatted ASCII Summary Text
asciiLines = [
    "========================================================================================="
    "                   ☄️ ASSTEROID SURROGATE MODEL GENERALIZATION REPORT                    "
    "========================================================================================="
    sprintf("%-18s | %-24s | %-20s | %-16s", "Target", "Tier 1: Test Holdout", "Tier 2: IDW Unbiased", "Tier 3: Optima RoI")
    sprintf("%-18s | %-7s %-8s %-7s | %-9s %-9s | %-8s %-7s", ...
        "", "NRMSE%", "NRMSLE%", "R^2", "NRMSE%", "R^2", "NRMSE%", "R^2")
    "-----------------------------------------------------------------------------------------"
];

for k = 1:numTargets
    tName = targetNames(k);
    roiNRMSE = NaN; roiR2 = NaN;
    if ~isempty(tblRoiCombined)
        roiIdx = find(string(tblRoiCombined.Target) == tName, 1);
        if ~isempty(roiIdx)
            roiNRMSE = tblRoiCombined.RoI_NRMSE_Pct(roiIdx);
            roiR2 = tblRoiCombined.RoI_R2(roiIdx);
        end
    end
    
    asciiLines(end + 1, 1) = sprintf("%-18s | %6.2f%% %7.2f%% %7.4f | %8.2f%% %9.4f | %7.2f%% %7.4f", ...
        extractBefore(tName + "                  ", 19), ...
        nrmseBiased(k), nrmsleBiased(k), r2Biased(k), ...
        nrmseIdw(k), r2Idw(k), roiNRMSE, roiR2); %#ok<AGROW>
end
asciiLines(end + 1, 1) = "=========================================================================================";
summaryText = strjoin(asciiLines, newline);

if options.Verbose
    fprintf("\n%s\n\n", summaryText);
end

%% 8. Pack Result Struct
perfReport = struct();
perfReport.globalBiased   = tblBiased;
perfReport.globalUnbiased = tblUnbiased;
perfReport.roiOptima      = tblRoiOptima;
perfReport.roiCombined    = tblRoiCombined;
perfReport.latexSummary   = latexSummary;
perfReport.summaryText    = summaryText;
perfReport.timestamp      = string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
perfReport.numTestSamples = N_test;
perfReport.numRoiSamples  = nnz(roiMaskAll);
perfReport.idwWeights     = idwWeights;
end
