function metricsNormalized = normalizeMetricNames(metricsInput)
% normalizeMetricNames  Normalize metric names to canonical form with alias resolution.
%
% metricsNormalized = normalizeMetricNames(metricsInput) accepts user-provided
% metric names (which may be abbreviated, contain spaces, or use aliases) and
% returns the canonical base metric names in stable order.
%
% Supported aliases:
%   'absorptance', 'abs'       -> 'Absorptance'
%   'm_vol', 'mvol'            -> 'M_vol'
%   'm_surf', 'msurf'          -> 'M_surf'
%   'ef_vol', 'efvol'          -> 'EF_vol'
%   'ef_surf', 'efsrf'         -> 'EF_surf'
%
% Derived metric aliases (mapped to their base metric):
%   'ef_vol_avg', 'bee_vol'       -> 'EF_vol'
%   'ef_surf_avg', 'bee_surf'     -> 'EF_surf'
%   'ef_vol_analyte', 'aee_vol'   -> 'EF_vol'
%   'ef_surf_analyte', 'aee_surf' -> 'EF_surf'
%   'ef_vol_laser', 'ef_vol_approx' -> 'EF_vol'
%   'ef_surf_laser', 'ef_surf_approx' -> 'EF_surf'
%
% Example:
%   metricsNormalized = normalizeMetricNames({'bee_vol', 'abs', 'EF_VOL'});
%   % Returns: {'EF_vol', 'Absorptance'} after unique stable sort

arguments
    metricsInput (1,:) string {mustBeNonmissing(metricsInput)}
end

% Define canonical targets and aliases
availableTargets = {'Absorptance','M_vol','M_surf','EF_vol','EF_surf'};
aliasKeys = {'absorptance','abs','m_vol','mvol','m_surf','msurf','ef_vol','efvol','ef_surf','efsrf', ...
             'bee_vol', 'bee_surf', 'aee_vol', 'aee_surf', 'ef_vol_laser', 'ef_surf_laser'};
aliasValues = {'Absorptance','Absorptance','M_vol','M_vol','M_surf','M_surf','EF_vol','EF_vol','EF_surf','EF_surf', ...
               'EF_vol', 'EF_surf', 'EF_vol', 'EF_surf', 'EF_vol', 'EF_surf'};
aliasMap = containers.Map(aliasKeys, aliasValues);

% Normalize input strings
normalizedInputs = lower(regexprep(string(metricsInput), '\s+', ''));
metricsCanonical = cell(size(normalizedInputs));

for idx = 1:numel(normalizedInputs)
    % Remove non-alphanumeric characters
    key = regexprep(normalizedInputs(idx), '[^a-z0-9_]', '');
    
    % Strip derived suffixes to map to base metric
    key = regexprep(key, '_(avg|analyte|laser|approx)$', '');
    
    % Attempt alias lookup
    if isKey(aliasMap, key)
        metricsCanonical{idx} = aliasMap(key);
    else
        % Try exact match against canonical names
        matchIdx = find(strcmpi(key, availableTargets), 1);
        if ~isempty(matchIdx)
            metricsCanonical{idx} = availableTargets{matchIdx};
        else
            % Accept dynamically detected metrics directly as char
            metricsCanonical{idx} = char(metricsInput(idx));
        end
    end
end

% Return unique values in stable order
metricsNormalized = unique(metricsCanonical, 'stable');
end
