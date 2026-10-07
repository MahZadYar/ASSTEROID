function visualizeMaximaResults(results, options)
    % visualizeMaximaResults  Visualise maxima localization results on pcolor maps.
    %
    %   visualizeMaximaResults(results) renders averaged metric maps with
    %   candidate seeds and refined maxima overlaid, using results returned
    %   by runLocalizationWorkflow.
    %
    %   visualizeMaximaResults(results, Name=Value) allows customisation of
    %   colormap, export options, and annotation styling.
    %
    %   This function separates visualisation from workflow logic, allowing
    %   CLI scripts and uihtml apps to render results differently while
    %   sharing the same workflow output.
    %
    %   Input:
    %       results — struct returned by runLocalizationWorkflow
    %
    %   Name-Value Arguments:
    %       ColormapFile    (1,1) string  — Path to custom colormap file
    %       ColormapSize    (1,1) double  — Colormap resolution (default: 4095)
    %       ExportGraphics  (1,1) logical — Save figures to PNG (default: false)
    %       ExportDir       (1,1) string  — Directory for exported graphics
    %       ShowAnnotations (1,1) logical — Show metric annotations (default: true)
    %       ParentAxes      — Optional axes handle for rendering into existing axes
    %
    %   Example:
    %       results = runLocalizationWorkflow(cfg, ProgressReporter.console());
    %       visualizeMaximaResults(results, ExportGraphics=true);
    %
    %   See also: runLocalizationWorkflow, localizeMaximaConfig, loadColormap

    arguments
        results (1,1) struct
        options.ColormapFile (1,1) string = ""
        options.ColormapSize (1,1) double {mustBePositive, mustBeInteger} = 4095
        options.ExportGraphics (1,1) logical = false
        options.ExportDir (1,1) string = string(pwd)
        options.ShowAnnotations (1,1) logical = true
        options.ParentAxes = []
    end

    % Load colormap
    if strlength(options.ColormapFile) > 0 && isfile(options.ColormapFile)
        cmap = flipud(loadColormap(options.ColormapFile, options.ColormapSize));
    else
        cmap = flipud(loadColormap("AuroraAustralis.txt", options.ColormapSize));
    end

    allData = results.allData;

    for metricIdx = 1:numel(results.metrics)
        mr = results.metrics{metricIdx};
        if isempty(mr) || isempty(mr.avgMetricGrid)
            continue;
        end

        primaryMetric = mr.metricName;
        primaryMetricAvgField = matlab.lang.makeValidName([primaryMetric, '_avg']);
        primaryMetricLabel = strrep(primaryMetric, '_', '\_');
        avgMetricGrid = mr.avgMetricGrid;
        pSamples = mr.pSamples;
        rSamples = mr.rSamples;

        % Create meshgrid in nm for display
        [pMesh, rMesh] = meshgrid(pSamples * 1e3, rSamples * 1e3);

        % Determine axes
        if ~isempty(options.ParentAxes)
            ax = options.ParentAxes;
        else
            figure;
            ax = gca;
        end

        hPcolor = pcolor(ax, pMesh, rMesh, avgMetricGrid);
        set(hPcolor, 'EdgeColor', 'none', 'FaceColor', 'interp');
        colormap(ax, cmap);
        xlabel(ax, 'p (nm)');
        ylabel(ax, 'r (nm)');

        % Get wavelength range from SoA
        lambdaGrid_nm = allData.lambda(1, :);
        if numel(lambdaGrid_nm) > 1
            title(ax, sprintf('Average %s across %.1f<λ<%.1f nm', ...
                primaryMetricLabel, lambdaGrid_nm(2), lambdaGrid_nm(end)));
        else
            title(ax, sprintf('Average %s at λ=%.1f nm', ...
                primaryMetricLabel, lambdaGrid_nm(1)));
        end
        colorbar(ax);
        hold(ax, 'on');

        legendEntries = {};
        legendHandles = [];

        % Plot refined maxima (hollow circles)
        maximaResults = mr.maximaResults;
        hasMaxima = istable(maximaResults) && height(maximaResults) > 0;

        % Plot candidate seeds
        candidateTable = mr.candidateTable;
        if ~isempty(candidateTable) && height(candidateTable) > 0
            hSeeds = scatter(ax, candidateTable.P_um * 1e3, candidateTable.R_um * 1e3, ...
                36, 'k', 'x', 'LineWidth', 1.1);
            legendHandles(end+1) = hSeeds; %#ok<AGROW>
            legendEntries{end+1} = 'Seeds'; %#ok<AGROW>
            
            % Add text annotations for seeds only when no optima are shown
            if options.ShowAnnotations && ~hasMaxima
                for idx = 1:height(candidateTable)
                    pVal = candidateTable.P_um(idx);
                    rVal = candidateTable.R_um(idx);
                    
                    % Get metric value
                    if ismember('GridValue', candidateTable.Properties.VariableNames)
                        metricVal = candidateTable.GridValue(idx);
                    else
                        metricVal = NaN;
                    end
                    
                    % Tag
                    tagStr = sprintf("Seed %d", idx);
                    
                    % Format annotation with bold tag on first line
                    if isfinite(metricVal)
                        valStr = sprintf("%.3f", metricVal);
                    else
                        valStr = "N/A";
                    end
                    
                    % Render as two-line cell array (bold tag on first line)
                    txtLines = {['\bf' char(tagStr) '\rm'], char(valStr)};

                    text(ax, pVal * 1e3, rVal * 1e3, txtLines, ...
                        'Interpreter', 'tex', ...
                        'Color', 'white', 'FontSize', 9, ...
                        'BackgroundColor', [0 0 0 0.6], 'EdgeColor', 'white', ...
                        'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
                        'Margin', 3);
                end
            end
        end

        if hasMaxima
            hMax = scatter(ax, maximaResults.P_um * 1e3, maximaResults.R_um * 1e3, ...
                100, 'w', 'o', 'MarkerEdgeColor', 'k', 'LineWidth', 1.5);
            legendHandles(end+1) = hMax; %#ok<AGROW>
            legendEntries{end+1} = 'Optimized'; %#ok<AGROW>

            % Annotations
            if options.ShowAnnotations
                for idx = 1:height(maximaResults)
                    pVal = maximaResults.P_um(idx);
                    rVal = maximaResults.R_um(idx);
                    
                    % Get metric value
                    if ismember('OptimizedValue', maximaResults.Properties.VariableNames)
                        metricVal = maximaResults.OptimizedValue(idx);
                    elseif ismember(primaryMetricAvgField, maximaResults.Properties.VariableNames)
                        metricVal = maximaResults.(primaryMetricAvgField)(idx);
                    else
                        metricVal = NaN;
                    end
                    
                    % Tag
                    tagStr = sprintf("Optimum %d", idx);
                    
                    % Format annotation with bold tag on first line
                    if isfinite(metricVal)
                        valStr = sprintf("%.3f", metricVal);
                    else
                        valStr = "N/A";
                    end

                    % Render as two-line cell array (bold tag on first line)
                    txtLines = {['\bf' char(tagStr) '\rm'], char(valStr)};

                    text(ax, pVal * 1e3, rVal * 1e3, txtLines, ...
                        'Interpreter', 'tex', ...
                        'Color', 'white', 'FontSize', 9, ...
                        'BackgroundColor', [0 0 0 0.6], 'EdgeColor', 'white', ...
                        'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
                        'Margin', 3);
                end
            end
        end

        if ~isempty(legendEntries)
            legend(ax, legendHandles, legendEntries, ...
                'Location', 'northeast');
        end

        hold(ax, 'off');

        % Export
        if options.ExportGraphics
            graphicFile = fullfile(options.ExportDir, ...
                sprintf('maxima_%s_%s.png', primaryMetric, char(datetime("now", "Format", "yyyyMMdd_HHmmss"))));
            saveas(gcf, graphicFile);
            fprintf('Exported maxima visualization to %s\n', graphicFile);
        end
    end
end
