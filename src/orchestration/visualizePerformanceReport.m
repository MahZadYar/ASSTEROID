function figOut = visualizePerformanceReport(perfReport, options)
%visualizePerformanceReport Plot three-tier surrogate performance diagnostics in UI panel.
%
%   visualizePerformanceReport(perfReport) creates a two-panel visualization
%   comparing Tier 1 (Holdout), Tier 2 (IDW Unbiased), and Tier 3 (Optima RoI).
%
%   visualizePerformanceReport(perfReport, Parent=panel) renders into an
%   existing uipanel or figure handle (e.g. right visualization panel in Stage 3).
%
%   Inputs:
%       perfReport – Struct from computeSurrogateEvaluationMetrics containing:
%                    .globalBiased, .globalUnbiased, .roiCombined, etc.
%       Parent     – (Optional) target figure or uipanel handle
%
%   See also: computeSurrogateEvaluationMetrics, visualizeTrainingResults, TrainingController

arguments
    perfReport (1,1) struct
    options.Parent = []
end

    if ~isfield(perfReport, "globalBiased") || isempty(perfReport.globalBiased)
        warning("visualizePerformanceReport:InvalidReport", "No globalBiased metrics table in perfReport.");
        return;
    end

    tblB = perfReport.globalBiased;
    tblU = perfReport.globalUnbiased;
    tblR = [];
    if isfield(perfReport, "roiCombined") && ~isempty(perfReport.roiCombined)
        tblR = perfReport.roiCombined;
    end

    targets = string(tblB.Target);
    numTargets = numel(targets);
    if numTargets == 0, return; end

    %% 1. Target container and styling
    if isempty(options.Parent)
        fig = figure("Name", "Surrogate Model Performance Report", ...
            "Color", [6, 8, 18]/255, "NumberTitle", "off", ...
            "Position", [120, 120, 960, 440]);
    else
        fig = options.Parent;
    end
    if nargout > 0, figOut = fig; end

    isDark = true;
    if isprop(fig, "BackgroundColor")
        bg = get(fig, "BackgroundColor");
        if isnumeric(bg) && numel(bg) == 3 && mean(bg) >= 0.5
            isDark = false;
        end
    end

    if isDark
        colBg     = [6, 8, 18]/255;
        colAxBg   = [12, 16, 32]/255;
        colText   = [0.90, 0.93, 0.96];
        colSub    = [0.60, 0.68, 0.76];
        colGrid   = [0.22, 0.28, 0.38];
        colT1     = [72, 178, 172]/255;  % ASSTEROID Teal (#48b2ac) (Tier 1: Holdout)
        colT2     = [153, 78, 243]/255;  % ASSTEROID Purple (#994ef3) (Tier 2: IDW)
        colT3     = [235, 179, 79]/255;  % ASSTEROID Gold (#ebb34f) (Tier 3: Optima RoI)
    else
        colBg     = [0.98, 0.98, 0.99];
        colAxBg   = [1.00, 1.00, 1.00];
        colText   = [0.10, 0.12, 0.16];
        colSub    = [0.35, 0.40, 0.48];
        colGrid   = [0.85, 0.88, 0.92];
        colT1     = [39, 146, 141]/255;  % Teal base
        colT2     = [127, 0, 224]/255;   % Purple base
        colT3     = [201, 148, 44]/255;  % Gold base
    end

    %% 2. Extract Data Matrices
    % Columns: Tier 1 (Holdout), Tier 2 (IDW), Tier 3 (RoI)
    nrmseMat = nan(numTargets, 3);
    r2Mat    = nan(numTargets, 3);

    for k = 1:numTargets
        tName = targets(k);
        % Tier 1
        nrmseMat(k, 1) = extractTableCol(tblB, ["NRMSE_Pct", "NRMSE_pct", "NRMSE"], k);
        r2Mat(k, 1)    = extractTableCol(tblB, ["R2", "R_squared", "Rsquared"], k);

        % Tier 2
        if ~isempty(tblU)
            nrmseMat(k, 2) = extractTableCol(tblU, ["IDW_NRMSE_Pct", "IDW_NRMSE_pct", "NRMSE_Pct", "NRMSE_pct", "NRMSE"], k);
            r2Mat(k, 2)    = extractTableCol(tblU, ["IDW_R2", "R2", "R_squared"], k);
        end

        % Tier 3
        if ~isempty(tblR)
            targetColIdx = find(strcmpi(tblR.Properties.VariableNames, "Target"), 1);
            if ~isempty(targetColIdx)
                rIdx = find(string(tblR.(tblR.Properties.VariableNames{targetColIdx})) == tName, 1);
                if ~isempty(rIdx)
                    nrmseMat(k, 3) = extractTableCol(tblR, ["RoI_NRMSE_Pct", "RoI_NRMSE_pct", "NRMSE_Pct", "NRMSE_pct", "NRMSE"], rIdx);
                    r2Mat(k, 3)    = extractTableCol(tblR, ["RoI_R2", "R2", "R_squared"], rIdx);
                end
            end
        end
    end

    %% 3. Layout Construction
    t = tiledlayout(fig, 1, 2, "TileSpacing", "compact", "Padding", "compact");
    
    numTest = 0;
    if isfield(perfReport, "numTestSamples"), numTest = perfReport.numTestSamples; end
    numRoi = 0;
    if isfield(perfReport, "numRoiSamples"), numRoi = perfReport.numRoiSamples; end
    
    titleStr = sprintf("Surrogate Generalization Audit (N_{test} = %d geometries, N_{roi} = %d samples)", ...
        numTest, numRoi);
    tTitle = title(t, titleStr, "FontWeight", "bold", "FontSize", 13);
    if isprop(tTitle, "Color"), tTitle.Color = colText; end

    seriesLabels = ["Tier 1: Holdout Split", "Tier 2: IDW Unbiased", "Tier 3: Optima RoI"];
    catTargets = categorical(targets, targets);

    %% 4. Tile 1: NRMSE (%) Grouped Bars (Logarithmic Y-Axis)
    ax1 = nexttile(t, 1);
    hold(ax1, "on");
    b1 = bar(ax1, catTargets, nrmseMat, "grouped");
    if numel(b1) >= 1, b1(1).FaceColor = colT1; b1(1).EdgeColor = "none"; end
    if numel(b1) >= 2, b1(2).FaceColor = colT2; b1(2).EdgeColor = "none"; end
    if numel(b1) >= 3, b1(3).FaceColor = colT3; b1(3).EdgeColor = "none"; end

    set(ax1, "YScale", "log");
    ylabel(ax1, "Normalized RMSE (%) [Log Scale]", "FontWeight", "bold");
    title(ax1, "Generalization Error: NRMSE (%) [Lower is Better]", "FontWeight", "bold");
    grid(ax1, "on");
    leg1 = legend(ax1, seriesLabels, "Location", "northwest");

    % NRMSE baseline limits [1e-1, 1e2]; lower bound expands smaller according to data
    validNrmse = nrmseMat(isfinite(nrmseMat) & nrmseMat > 0);
    yBottom = 0.1;   % 1e-1 baseline
    yTop    = 100;   % 1e2 baseline
    if ~isempty(validNrmse)
        minNrmse = min(validNrmse);
        maxNrmse = max(validNrmse);
        if minNrmse < yBottom
            yBottom = 10^(floor(log10(minNrmse)));
        end
        if maxNrmse > yTop
            yTop = 10^(ceil(log10(maxNrmse)));
        end
    end
    ax1.YLim = [yBottom, yTop];
    for i = 1:numel(b1)
        b1(i).BaseValue = yBottom;
    end

    % Value text annotations above bars (proportional spacing for log scale)
    for i = 1:numel(b1)
        xEnd = b1(i).XEndPoints;
        yEnd = b1(i).YEndPoints;
        for j = 1:numel(xEnd)
            if isfinite(yEnd(j)) && yEnd(j) > 0
                yTextPos = min(yEnd(j) * 1.15, yTop * 0.90);
                text(ax1, xEnd(j), yTextPos, ...
                    sprintf("%.2f%%", yEnd(j)), ...
                    "HorizontalAlignment", "center", "VerticalAlignment", "bottom", ...
                    "FontSize", 8, "FontWeight", "bold", "Color", colText);
            end
        end
    end
    applyAxisTheme(ax1, isDark, colAxBg, colText, colGrid, leg1);

    %% 5. Tile 2: R^2 Grouped Bars (Fixed Linear [0, 1])
    ax2 = nexttile(t, 2);
    hold(ax2, "on");
    b2 = bar(ax2, catTargets, r2Mat, "grouped");
    if numel(b2) >= 1, b2(1).FaceColor = colT1; b2(1).EdgeColor = "none"; end
    if numel(b2) >= 2, b2(2).FaceColor = colT2; b2(2).EdgeColor = "none"; end
    if numel(b2) >= 3, b2(3).FaceColor = colT3; b2(3).EdgeColor = "none"; end

    % Ideal reference line at R^2 = 1.0
    yline(ax2, 1.0, "--", "Ideal (R^2 = 1.0)", "Color", [1.0, 0.4, 0.4], ...
        "LineWidth", 1.2, "LabelHorizontalAlignment", "left", "LabelVerticalAlignment", "middle");

    ylabel(ax2, "Coefficient of Determination (R^2)", "FontWeight", "bold");
    title(ax2, "Predictive Fidelity: R^2 Score [Higher is Better]", "FontWeight", "bold");
    grid(ax2, "on");
    leg2 = legend(ax2, seriesLabels, "Location", "southwest");

    % Fixed linear Y-limits [0, 1]
    set(ax2, "YScale", "linear");
    ax2.YLim = [0, 1];
    ax2.YTick = 0:0.2:1.0;

    % Value text annotations inside/above bars
    for i = 1:numel(b2)
        xEnd = b2(i).XEndPoints;
        yEnd = b2(i).YEndPoints;
        for j = 1:numel(xEnd)
            if isfinite(yEnd(j))
                if yEnd(j) >= 0.80
                    % Position inside bar near top to avoid clipping at YLim = 1.0
                    yPos = max(0.05, yEnd(j) - 0.04);
                    vAlign = "top";
                    txtCol = [1, 1, 1]; % High-contrast white inside filled bar
                elseif yEnd(j) > 0
                    yPos = min(0.98, yEnd(j) + 0.02);
                    vAlign = "bottom";
                    txtCol = colText;
                else
                    yPos = 0.02;
                    vAlign = "bottom";
                    txtCol = colText;
                end
                text(ax2, xEnd(j), yPos, ...
                    sprintf("%.3f", yEnd(j)), ...
                    "HorizontalAlignment", "center", "VerticalAlignment", vAlign, ...
                    "FontSize", 8, "FontWeight", "bold", "Color", txtCol);
            end
        end
    end
    applyAxisTheme(ax2, isDark, colAxBg, colText, colGrid, leg2);
end

function applyAxisTheme(ax, isDark, colAxBg, colText, colGrid, leg)
    ax.Color = colAxBg;
    ax.XColor = colText;
    ax.YColor = colText;
    ax.GridColor = colGrid;
    ax.GridAlpha = 0.6;
    ax.Box = "on";
    if isprop(ax.Title, "Color"), ax.Title.Color = colText; end
    if isprop(ax.YLabel, "Color"), ax.YLabel.Color = colText; end
    if ~isempty(leg) && isvalid(leg)
        if isDark
            set(leg, "TextColor", colText, "Color", [0.08, 0.12, 0.22], "EdgeColor", colGrid);
        else
            set(leg, "TextColor", colText, "Color", [1.0, 1.0, 1.0], "EdgeColor", colGrid);
        end
    end
end

function val = extractTableCol(tbl, candidates, rowIdx)
    val = NaN;
    if isempty(tbl) || ~istable(tbl), return; end
    vn = tbl.Properties.VariableNames;
    for c = string(candidates)
        mIdx = find(strcmpi(vn, c), 1);
        if ~isempty(mIdx)
            val = double(tbl.(vn{mIdx})(rowIdx));
            return;
        end
    end
end

