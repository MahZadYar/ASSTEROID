addpath(genpath('src'));
try
    metricNames = "Absorptance";
    gf = struct('metricWeights', 1, 'metricAlphas', 1);
    nM = 1;
    
    cfg = adaptiveSamplingConfig( ...
        WorkDir = pwd, DataSource = 'interpolation', ...
        MetricNames = metricNames, ...
        MetricWeights = padVec(gf.metricWeights, nM), ...
        MetricAlphas = padVec(gf.metricAlphas, nM));
    disp('Success!');
catch ME
    disp(ME.identifier);
    disp(ME.message);
end

function v = padVec(v, n)
    if isempty(v), v = ones(1,n); return; end
    if iscell(v), v = cell2mat(v); end
    v = double(v(:)');
    if numel(v)<n, v = [v ones(1,n-numel(v))]; elseif numel(v)>n, v = v(1:n); end
end
