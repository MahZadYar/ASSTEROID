function visualizeImportSummary(results, options)
%visualizeImportSummary Quick QA plots after COMSOL sweep import.
%
%   visualizeImportSummary(results) creates diagnostic plots from
%   runImportSweepWorkflow output: geometry coverage, wavelength range,
%   and per-metric heatmaps.
%
%   visualizeImportSummary(results, Parent=fig) renders into an existing
%   figure or uipanel handle.
%
%   Inputs:
%       results  – struct from runImportSweepWorkflow
%       Parent   – (optional) target figure/panel handle
%
%   Example:
%       results = runImportSweepWorkflow(cfg, ProgressReporter.console());
%       visualizeImportSummary(results);
%
%   See also: runImportSweepWorkflow, importSweepConfig

arguments
    results  (1,1) struct
    options.Parent = []
end

    allData = results.allData;
    summary = results.summary;

    if isempty(allData) || ~isfield(allData, "period")
        warning("visualizeImportSummary:NoData", "No data to visualize.");
        return
    end

    N = structRowCount(allData);

    if isempty(options.Parent)
        fig = figure("Name", "Import Summary", ...
            "Color", "w", "NumberTitle", "off", ...
            "Position", [100 100 1200 800]);
    else
        fig = options.Parent;
    end

    t = tiledlayout(fig, 2, 3, "TileSpacing", "compact", "Padding", "compact");
    title(t, sprintf("Import Summary — %d entries from %s", N, summary.inputFile), ...
        "Interpreter", "none");

    %% 1. Geometry scatter
    ax1 = nexttile(t);
    if isfield(allData, "period") && isfield(allData, "radius")
        p = allData.period(:);
        r = allData.radius(:);
        scatter(ax1, p, r, 20, "filled", "MarkerFaceAlpha", 0.6);
        xlabel(ax1, "Period (nm)");
        ylabel(ax1, "Radius (nm)");
        title(ax1, "Geometry Coverage");
        grid(ax1, "on");
    end

    %% 2. Wavelength count per entry
    ax2 = nexttile(t);
    if isfield(allData, "lambda")
        if iscell(allData.lambda)
            nLambda = cellfun(@numel, allData.lambda);
        else
            nLambda = sum(isfinite(allData.lambda), 2);
        end
        histogram(ax2, nLambda, "FaceColor", [0.2 0.6 0.9]);
        xlabel(ax2, "# Wavelength Points");
        ylabel(ax2, "Count");
        title(ax2, "Spectral Resolution");
        grid(ax2, "on");
    end

    %% 3. Import statistics
    ax3 = nexttile(t);
    labels = {"Total", "New", "Replaced", "Skipped"};
    vals   = [summary.totalEntries, summary.newEntries, ...
              summary.replacedDuplicates, summary.skippedExisting];
    barh(ax3, categorical(labels), vals, "FaceColor", [0.3 0.7 0.4]);
    xlabel(ax3, "Entries");
    title(ax3, "Import Statistics");
    grid(ax3, "on");

    %% 4. EE_V_broad / EF_vol_avg distribution
    ax4 = nexttile(t);
    evField = resolveDerivedMetricField("EE_V", "broad", allData);
    if isfield(allData, evField)
        ev = allData.(evField)(:);
        ev = ev(~isnan(ev) & ev > 0);
        if ~isempty(ev)
            histogram(ax4, log10(ev), 30, "FaceColor", [0.9 0.4 0.2]);
            xlabel(ax4, "log_{10}(EE_{V,broad})");
            ylabel(ax4, "Count");
            title(ax4, "EE_V Broadband Distribution");
            grid(ax4, "on");
        end
    end

    %% 5. EE_V_broad heatmap (period × radius)
    ax5 = nexttile(t);
    if isfield(allData, evField) && isfield(allData, "period") && isfield(allData, "radius")
        p = allData.period(:);
        r = allData.radius(:);
        ev = allData.(evField)(:);
        validMask = ~isnan(ev) & ev > 0;
        if nnz(validMask) > 2
            scatter(ax5, p(validMask), r(validMask), 36, log10(ev(validMask)), "filled");
            colorbar(ax5);
            xlabel(ax5, "Period (nm)");
            ylabel(ax5, "Radius (nm)");
            title(ax5, "log_{10}(EE_{V,broad}) Map");
            grid(ax5, "on");
        end
    end

    %% 6. Absorptance map
    ax6 = nexttile(t);
    abField = resolveDerivedMetricField("Abs", "laser", allData);
    if ~isfield(allData, abField)
        abField = resolveDerivedMetricField("Abs", "broad", allData);
    end
    if isfield(allData, abField) && isfield(allData, "period") && isfield(allData, "radius")
        p = allData.period(:);
        r = allData.radius(:);
        ab = allData.(abField)(:);
        validMask = ~isnan(ab);
        if nnz(validMask) > 2
            scatter(ax6, p(validMask), r(validMask), 36, ab(validMask), "filled");
            colorbar(ax6);
            xlabel(ax6, "Period (nm)");
            ylabel(ax6, "Radius (nm)");
            title(ax6, "Abs Map");
            grid(ax6, "on");
        end
    end
end
