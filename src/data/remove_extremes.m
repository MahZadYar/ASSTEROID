workDir = pwd;
filename = "prl_sweep.mat";
exportFilename = "prl_sweep.mat";
if ~isfile(filename)
    error('File not found: %s in directory %s', filename, workDir);
end

load(filename, 'allData');

if ~isstruct(allData) || ~all(isfield(allData, {'p','r'}))
    error('allData must contain p and r fields.');
end

switchInterpolate = true; % when false, offending rows are dropped entirely
threshold = 0.492;

pVals = allData.p(:);
rVals = allData.r(:);
if numel(pVals) ~= numel(rVals)
    error('Size mismatch between p and r vectors.');
end

ratio = rVals ./ pVals;
invalidIdx = ratio > threshold;
validIdx = ~invalidIdx;

if ~any(invalidIdx)
    fprintf('No entries exceed the r/p threshold of %.3f; no changes applied.\n', threshold);
    return;
end

fieldNames = fieldnames(allData);

if switchInterpolate
    rClamped = rVals;
    rClamped(invalidIdx) = pVals(invalidIdx) .* threshold;

    for i = 1:numel(fieldNames)
        fn = fieldNames{i};
        value = allData.(fn);

        if isnumeric(value) || islogical(value)
            if size(value, 1) ~= numel(rVals)
                continue; % Skip non row-aligned fields (spectra etc.)
            end

            if size(value, 2) == 1
                F = scatteredInterpolant(pVals(validIdx), rVals(validIdx), double(value(validIdx)), ...
                    'natural', 'nearest');
                value(invalidIdx) = F(pVals(invalidIdx), rClamped(invalidIdx));
                allData.(fn) = value;
            else
                % Apply interpolation column-wise for matrices with matching row count
                for col = 1:size(value, 2)
                    F = scatteredInterpolant(pVals(validIdx), rVals(validIdx), double(value(validIdx, col)), ...
                        'natural', 'nearest');
                    value(invalidIdx, col) = F(pVals(invalidIdx), rClamped(invalidIdx));
                end
                allData.(fn) = value;
            end
        end
    end

    allData.r = reshape(rClamped, size(allData.r));



save(exportFilename, 'allData');
fprintf('Updated dataset saved to %s.\n', exportFilename);

