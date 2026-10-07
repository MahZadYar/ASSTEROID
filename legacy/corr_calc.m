

workDir = "D:\OneDrive - Kaunas University of Technology\~Science Projects\NanoTRAACES\Experiment Data\WP01 Design\Data Analysis";
cd(workDir); % Change to working directory
filename = "prl_sweep.mat";
if ~isfile(filename)
    error('File not found: %s', filename);
end
load(filename,'allData');

%% Define metric sets
metricSet1 = {'EF_vol','EF_surf','E_vol','E_surf', ...
                'M_vol','M_surf','M2_vol','M2_surf', ...
                'intW_vol','Absorptance','EF_vol_M', ...
                'EF_surf_M','EF_Abs'};

metricSet2 = {'EF_vol_avg','EF_surf_avg', ...
                'EF_vol_approx','EF_surf_approx', ...
                'EF_vol_M_avg','EF_surf_M_avg', ...
                'M_vol_laser','M_surf_laser', ...
                'Abs_laser','EF_Abs_avg'};

%% Process both metric sets
metricSets = {metricSet1, metricSet2};
setNames = {'metricSet1', 'metricSet2'};

for setIdx = 1:numel(metricSets)
    metricNames = metricSets{setIdx};
    setName = setNames{setIdx};
    
    fprintf('\n========================================\n');
    fprintf('Processing %s (%d metrics)\n', setName, numel(metricNames));
    fprintf('========================================\n');
    
    % Collect numeric vectors for each requested metric
    cols = {};
    labels = {};
    for k = 1:numel(metricNames)
        name = metricNames{k};
        if ~isfield(allData, name)
            warning('Field "%s" not found in allData; skipping.', name);
            continue;
        end
        v = allData.(name);
        if ~isnumeric(v) && ~islogical(v)
            warning('Field "%s" is not numeric; skipping.', name);
            continue;
        end

        % Turn into a column vector A(:) but preserve NaNs
        vec = v(:);
        cols{end+1} = double(vec); %#ok<AGROW>
        labels{end+1} = name; %#ok<AGROW>
    end

    if isempty(cols)
        warning('No numeric fields found for %s; skipping.', setName);
        continue;
    end

    % Build data matrix with one column per metric
    maxRows = max(cellfun(@numel, cols));
    M = nan(maxRows, numel(cols));
    for j = 1:numel(cols)
        colj = cols{j};
        M(1:numel(colj), j) = colj;
    end

    % Compute pairwise Pearson correlation using pairwise-complete rows
    C = corrcoef(log(M), 'Rows', 'pairwise');
    corrTable = array2table(C, 'VariableNames', labels, 'RowNames', labels);

    % Export table to csv
    [~, baseName, ~] = fileparts(filename);
    outcsv = fullfile(workDir, sprintf('%s_correlation_%s.csv', baseName, setName));
    writetable(corrTable, char(outcsv), 'WriteRowNames', true);
    fprintf('Correlation matrix saved to: %s\n', outcsv);
    
    % Display results as a labeled table
    fprintf('\nPairwise Pearson correlation (pairwise-complete rows) - %s:\n', setName);
    disp(corrTable);

    % Show number of valid pairs used for each correlation
    Npairs = zeros(size(C));
    for i = 1:size(M,2)
        for j = 1:size(M,2)
            valid = ~isnan(M(:,i)) & ~isnan(M(:,j));
            Npairs(i,j) = sum(valid);
        end
    end
    fprintf('\nNumber of pairwise-valid rows used for each correlation - %s:\n', setName);
    disp(array2table(Npairs, 'VariableNames', labels, 'RowNames', labels));
    
    % Export valid pairs count
    outNpairs = fullfile(workDir, sprintf('%s_correlation_%s_npairs.csv', baseName, setName));
    validPairsTable = array2table(Npairs, 'VariableNames', labels, 'RowNames', labels);
    writetable(validPairsTable, char(outNpairs), 'WriteRowNames', true);
    fprintf('Valid pairs count saved to: %s\n', outNpairs);
end

fprintf('\n========================================\n');
fprintf('Correlation analysis complete.\n');
fprintf('========================================\n');