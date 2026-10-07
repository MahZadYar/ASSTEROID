function plotOptimizeHeatmap(results, baseMetric, metricVariant, ax, originalSeeds, refinedOptima, attemptTrajectories, showMultiStartPaths)
%plotOptimizeHeatmap Plot metric heatmap with seeds, optima, and trajectories.
%   Renders a pcolor heatmap for the specified metric from localization results,
%   overlaying original seed positions (X), refined optima (filled circles with
%   annotations), and optional MultiStart iteration paths.
%
%   plotOptimizeHeatmap(results, baseMetric, metricVariant, ax, ...)
%
%   Inputs:
%       results              - Localization workflow results struct with .allData.
%       baseMetric           - Base metric name (e.g., "EF_vol").
%       metricVariant        - Variant: "avg", "laser", or "weighted"/"analyte".
%       ax                   - Target axes handle.
%       originalSeeds        - (optional) Struct array of original seeds with .P, .R.
%       refinedOptima        - (optional) Struct array of refined optima.
%       attemptTrajectories  - (optional) Struct array from extractAttemptTrajectories.
%       showMultiStartPaths  - (optional) Logical, whether to draw iteration paths.

    arguments
        results struct
        baseMetric string
        metricVariant string
        ax
        originalSeeds = []
        refinedOptima = []
        attemptTrajectories = []
        showMultiStartPaths (1,1) logical = false
    end

    if ~isfield(results, "allData") || isempty(results.allData)
        text(ax, 0.5, 0.5, "No data available", HorizontalAlignment="center");
        return;
    end

    allData = results.allData;

    % Resolve derived field name (canonical: _avg/_analyte/_laser)
    if metricVariant == "weighted"
        variantForField = "analyte";
    elseif metricVariant == "laser"
        variantForField = "laser";
    else
        variantForField = "avg";
    end
    avgFieldName = resolveDerivedMetricField(baseMetric, variantForField, allData);
    if ~isfield(allData, avgFieldName)
        text(ax, 0.5, 0.5, "Metric data not available: " + avgFieldName, HorizontalAlignment="center");
        return;
    end

    avgData = allData.(avgFieldName);

    % Reshape to 2D grid
    P = double(allData.period(:));
    R = double(allData.radius(:));
    pUniq = unique(P);
    rUniq = unique(R);

    [pGrid, rGrid] = meshgrid(pUniq, rUniq);
    Z = NaN(size(pGrid));

    for i = 1:numel(P)
        pi = find(abs(pUniq - P(i)) < 1e-6, 1);
        ri = find(abs(rUniq - R(i)) < 1e-6, 1);
        if ~isempty(pi) && ~isempty(ri) && i <= numel(avgData)
            Z(ri, pi) = double(avgData(i));
        end
    end

    if ~isnumeric(Z) || all(isnan(Z(:))) || isempty(Z)
        text(ax, 0.5, 0.5, "No valid data for metric: " + avgFieldName, HorizontalAlignment="center");
        return;
    end

    pGrid = double(pGrid);
    rGrid = double(rGrid);
    Z = double(Z);

    if ~isvalid(ax) || ~isgraphics(ax, "axes")
        fprintf("[plotOptimizeHeatmap] ERROR: Invalid axes object\n");
        return;
    end

    % Plot heatmap
    cla(ax);
    pcolor(ax, pGrid, rGrid, Z);
    shading(ax, "interp");
    cmap = flipud(loadColormap("AuroraAustralis.txt", 256));
    colormap(ax, cmap);
    colorbar(ax);
    xlabel(ax, "Period (nm)");
    ylabel(ax, "Radius (nm)");
    if metricVariant == "laser"
        title(ax, baseMetric + " (at laser \lambda)");
    elseif metricVariant == "weighted"
        title(ax, baseMetric + " (analyte-weighted avg)");
    else
        title(ax, baseMetric + " (spectral avg)");
    end
    axis(ax, "tight");
    hold(ax, "on");

    % Determine seed count for color assignment
    seedCount = 0;
    if ~isempty(originalSeeds), seedCount = max(seedCount, numel(originalSeeds)); end
    if ~isempty(refinedOptima), seedCount = max(seedCount, numel(refinedOptima)); end
    if ~isempty(attemptTrajectories)
        seedCount = max(seedCount, max(arrayfun(@(t) t.SeedIndex, attemptTrajectories)));
    end
    seedCount = max(1, seedCount);
    seedColors = lines(seedCount);

    % Overlay original seed positions (empty O markers)
    if ~isempty(originalSeeds)
        originalSeeds = originalSeeds(:);
        for i = 1:numel(originalSeeds)
            s = originalSeeds(i);
            if isstruct(s) && isfield(s, "P") && isfield(s, "R")
                pVal = double(s.P);
                rVal = double(s.R);
                if isfinite(pVal) && isfinite(rVal)
                    sIdx = max(1, min(i, size(seedColors, 1)));
                    clr = seedColors(sIdx, :);
                    plot(ax, pVal, rVal, "o", MarkerSize=6, ...
                        MarkerFaceColor="none", MarkerEdgeColor=clr, ...
                        HandleVisibility="off");
                end
            end
        end
    end

    % Overlay refined optima (filled circles with annotations)
    if ~isempty(refinedOptima)
        refinedOptima = refinedOptima(:);
        for i = 1:numel(refinedOptima)
            s = refinedOptima(i);
            if isstruct(s) && isfield(s, "P") && isfield(s, "R")
                pVal = double(s.P);
                rVal = double(s.R);
                if isfinite(pVal) && isfinite(rVal)
                    sIdx = max(1, min(i, size(seedColors, 1)));
                    clr = seedColors(sIdx, :);
                    plot(ax, pVal, rVal, "o", MarkerSize=7, ...
                        MarkerFaceColor=clr, MarkerEdgeColor=clr, ...
                        LineWidth=1.2, HandleVisibility="off");
                end
            end
        end

        % Text annotations with detail overlay
        for i = 1:numel(refinedOptima)
            s = refinedOptima(i);
            if isstruct(s) && isfield(s, "P") && isfield(s, "R")
                if isfield(s, "Tag") && strlength(s.Tag) > 0
                    tagStr = string(s.Tag);
                else
                    tagStr = sprintf("Optimum %d", i);
                end

                if isfield(s, "Value") && isfinite(s.Value)
                    valStr = sprintf("%.3f", s.Value);
                else
                    valStr = "N/A";
                end

                pStr = sprintf("p=%.1f", s.P);
                rStr = sprintf("r=%.1f", s.R);

                txtLines = {['\bf' char(tagStr) '\rm'], ...
                            char(pStr + ", " + rStr), ...
                            char(baseMetric + " = " + valStr)};

                try
                    t = text(ax, s.P, s.R, txtLines, ...
                        Interpreter="tex", ...
                        Color="white", FontSize=9, ...
                        BackgroundColor="none", EdgeColor="none", ...
                        HorizontalAlignment="center", VerticalAlignment="bottom", ...
                        Margin=3);
                    drawnow;

                    ext = get(t, "Extent");
                    xRange = diff(ax.XLim);
                    yRange = diff(ax.YLim);
                    padX = max(0.002 * xRange, 0.5);
                    padY = max(0.008 * yRange, 0.5);
                    rectPos = [ext(1) - padX, ext(2) - padY, ext(3) + 2 * padX, ext(4) + 2 * padY];

                    hRect = rectangle(ax, Position=rectPos, FaceColor=[0 0 0], EdgeColor="none");
                    hRect.FaceAlpha = 0.25;

                    try
                        uistack(hRect, "bottom");
                        uistack(t, "top");
                    catch
                    end
                catch textErr
                    fprintf("[plotOptimizeHeatmap] Annotation warning: %s\n", textErr.message);
                end
            end
        end
    end

    % Overlay MultiStart attempt paths
    if showMultiStartPaths && ~isempty(attemptTrajectories)
        renderTrajectoryPaths(ax, attemptTrajectories, seedColors);
    end

    % Overlay raw data measurement points (interpolation mode)
    if isfield(allData, "rawDataPoints") && isstruct(allData.rawDataPoints)
        rawPts = allData.rawDataPoints;
        if isfield(rawPts, "P") && isfield(rawPts, "R")
            plot(ax, rawPts.P, rawPts.R, "k.", MarkerSize=4, DisplayName="Raw data points");
        end
    end

    % Custom data cursor for diagnostics
    dcm = datacursormode(ancestor(ax, "figure"));
    dcm.UpdateFcn = @optimizeHeatmapDataCursorText;

    hold(ax, "off");
end

function renderTrajectoryPaths(ax, trajectories, seedColors)
%renderTrajectoryPaths Draw MultiStart iteration paths on axes.
    trajectories = trajectories(:);
    for i = 1:numel(trajectories)
        tr = trajectories(i);
        if ~isstruct(tr) || ~isfield(tr, "StartP") || ~isfield(tr, "StartR") || ...
                ~isfield(tr, "EndP") || ~isfield(tr, "EndR")
            continue;
        end
        if ~(isfinite(tr.StartP) && isfinite(tr.StartR) && isfinite(tr.EndP) && isfinite(tr.EndR))
            continue;
        end
        try
            sIdx = max(1, min(tr.SeedIndex, size(seedColors, 1)));
            clr = seedColors(sIdx, :);
            isAccepted = true;
            if isfield(tr, "Accepted"), isAccepted = logical(tr.Accepted); end
            lineClr = 0.75 * clr + 0.25;

            hasIterPath = isfield(tr, "IterPath") && isstruct(tr.IterPath) && ...
                isfield(tr.IterPath, "x") && size(tr.IterPath.x, 1) > 1;
            if hasIterPath
                pathX = tr.IterPath.x;
                nPts = size(pathX, 1);
                arrowFrac = 0.35;
                for seg = 1:(nPts - 1)
                    x1 = pathX(seg, 1);  y1 = pathX(seg, 2);
                    x2 = pathX(seg + 1, 1);  y2 = pathX(seg + 1, 2);
                    dx = x2 - x1;  dy = y2 - y1;
                    plot(ax, [x1, x2], [y1, y2], "-", ...
                        Color=lineClr, LineWidth=0.5, HandleVisibility="off");
                    len = hypot(dx, dy);
                    if len > 0
                        ux = dx * arrowFrac;
                        uy = dy * arrowFrac;
                        quiver(ax, x2 - ux, y2 - uy, ux, uy, 0, ...
                            Color=lineClr, LineWidth=0.5, ...
                            MaxHeadSize=2, HandleVisibility="off");
                    end
                end
                if nPts > 2
                    dotClr = 0.5 * clr + 0.5;
                    plot(ax, pathX(2:end-1, 1), pathX(2:end-1, 2), ...
                        ".", Color=dotClr, MarkerSize=4, HandleVisibility="off");
                end
            else
                plot(ax, [tr.StartP, tr.EndP], [tr.StartR, tr.EndR], ...
                    "-", Color=lineClr, LineWidth=0.5, HandleVisibility="off");
            end

            ud = buildTrajectoryUserData(tr, hasIterPath);
            if isAccepted
                h = plot(ax, tr.StartP, tr.StartR, ".", Color=clr, ...
                    MarkerSize=5, HandleVisibility="off");
            else
                rejClr = 0.6 * clr + 0.4;
                h = plot(ax, tr.StartP, tr.StartR, "x", Color=rejClr, ...
                    LineWidth=0.8, MarkerSize=6, HandleVisibility="off");
            end
            h.UserData = ud;
        catch pathErr
            fprintf("[plotOptimizeHeatmap] Trajectory warning: %s\n", pathErr.message);
        end
    end
end

function ud = buildTrajectoryUserData(tr, hasIterPath)
%buildTrajectoryUserData Build UserData struct for trajectory marker diagnostics.
    ud = struct();
    if isfield(tr, "ExitFlag") && isfield(tr, "ConstrViol") && ...
       isfield(tr, "Iterations") && isfield(tr, "FirstOrderOpt") && isfield(tr, "DistFromSeed")
        ud.SeedIndex = tr.SeedIndex;
        ud.ExitFlag = tr.ExitFlag;
        ud.Iterations = tr.Iterations;
        ud.ConstrViol = tr.ConstrViol;
        ud.FirstOrderOpt = tr.FirstOrderOpt;
        ud.DistFromSeed = tr.DistFromSeed;
        if isfield(tr, "Accepted")
            ud.Accepted = logical(tr.Accepted);
        end
        if hasIterPath
            ud.IterSteps = size(tr.IterPath.x, 1);
        end
    end
end

function txt = optimizeHeatmapDataCursorText(~, event_obj)
%optimizeHeatmapDataCursorText Custom datacursor text for heatmap diagnostics.
    pos = event_obj.Position;
    target = event_obj.Target;

    txt = {sprintf("Period: %.1f nm", pos(1)), ...
           sprintf("Radius: %.1f nm", pos(2))};

    if isstruct(target.UserData) && isfield(target.UserData, "SeedIndex")
        ud = target.UserData;
        txt{end + 1} = "──────────────";
        txt{end + 1} = sprintf("Seed: #%d", ud.SeedIndex);
        if isfield(ud, "Accepted")
            if ud.Accepted
                txt{end + 1} = "Status: ACCEPTED";
            else
                txt{end + 1} = "Status: REJECTED";
            end
        end
        if isfield(ud, "ExitFlag")
            txt{end + 1} = sprintf("ExitFlag: %d", ud.ExitFlag);
        end
        if isfield(ud, "Iterations")
            if isnan(ud.Iterations)
                txt{end + 1} = "Iterations: N/A";
            else
                txt{end + 1} = sprintf("Iterations: %d", ud.Iterations);
            end
        end
        if isfield(ud, "IterSteps")
            txt{end + 1} = sprintf("Tracked steps: %d", ud.IterSteps);
        end
        if isfield(ud, "ConstrViol")
            txt{end + 1} = sprintf("ConstrViol: %.2e", ud.ConstrViol);
        end
        if isfield(ud, "FirstOrderOpt")
            txt{end + 1} = sprintf("OptGap: %.2e", ud.FirstOrderOpt);
        end
        if isfield(ud, "DistFromSeed")
            txt{end + 1} = sprintf("Dist: %.2f nm", ud.DistFromSeed);
        end
    end
end
