function metricsNormalized = normalizeMetricNames(metricsInput)
% normalizeMetricNames  Normalize metric names to canonical form with alias resolution.
%
% metricsNormalized = normalizeMetricNames(metricsInput) accepts user-provided
% metric names (which may be abbreviated, contain spaces, or use aliases) and
% returns the canonical base metric names in stable order.
%
% Supported canonical base metrics & aliases:
%   'ee_v', 'eev', 'ee_vol'                 -> 'EE_V'
%   'ee_s', 'ees', 'ee_surf'                -> 'EE_S'
%   'ef_max', 'efmax', 'm2_max', 'm2max'    -> 'EF_max'
%   'abs'                                   -> 'Abs'
%   'absorptance'                           -> 'Absorptance'
%   'ecc', 'eccheck'                        -> 'ECC'
%   'kappa_v', 'kappav', 'v_corr', 'volcorr'-> 'kappa_V'
%   'kappa_s', 'kappas', 's_corr', 'surfcorr'-> 'kappa_S'
%   'm_vol', 'mvol'                         -> 'M_vol'
%   'm_surf', 'msurf'                       -> 'M_surf'
%   'ef_vol', 'efvol'                       -> 'EF_vol'
%   'ef_surf', 'efsrf'                      -> 'EF_surf'
%
% Derived metric suffixes stripped to their base metric:
%   _(broad|broadband|avg|analyte|weighted|laser|approx)$
%   'bee_vol'       -> 'EF_vol'
%   'bee_surf'      -> 'EF_surf'
%   'aee_vol'       -> 'EF_vol'
%   'aee_surf'      -> 'EF_surf'
%
% Example:
%   metricsNormalized = normalizeMetricNames({'ee_v_broad', 'abs_laser', 'EF_MAX'});
%   % Returns: {'EE_V', 'Abs', 'EF_max'} after unique stable sort

arguments
    metricsInput (1,:) string {mustBeNonmissing(metricsInput)}
end

% Define canonical targets and aliases
availableTargets = {'EE_V','EE_S','EF_max','Abs','ECC','kappa_V','kappa_S', ...
                    'Absorptance','M_vol','M_surf','EF_vol','EF_surf','ECCheck'};
aliasKeys = {'ee_v','eev','ee_vol','eevol', ...
             'ee_s','ees','ee_surf','eesurf', ...
             'ef_max','efmax','m2_max','m2max','ef_laser_max', ...
             'abs','absorptance', ...
             'ecc','eccheck', ...
             'kappa_v','kappav','v_corr','volcorr', ...
             'kappa_s','kappas','s_corr','surfcorr', ...
             'm_vol','mvol','m_surf','msurf','ef_vol','efvol','ef_surf','efsrf', ...
             'bee_vol', 'bee_surf', 'aee_vol', 'aee_surf', 'ef_vol_laser', 'ef_surf_laser'};
aliasValues = {'EE_V','EE_V','EE_V','EE_V', ...
               'EE_S','EE_S','EE_S','EE_S', ...
               'EF_max','EF_max','EF_max','EF_max','EF_max', ...
               'Abs','Absorptance', ...
               'ECC','ECC', ...
               'kappa_V','kappa_V','kappa_V','kappa_V', ...
               'kappa_S','kappa_S','kappa_S','kappa_S', ...
               'M_vol','M_vol','M_surf','M_surf','EF_vol','EF_vol','EF_surf','EF_surf', ...
               'EF_vol', 'EF_surf', 'EF_vol', 'EF_surf', 'EF_vol', 'EF_surf'};
aliasMap = containers.Map(aliasKeys, aliasValues);

% Normalize input strings
normalizedInputs = lower(regexprep(string(metricsInput), '\s+', ''));
metricsCanonical = cell(size(normalizedInputs));

for idx = 1:numel(normalizedInputs)
    % Remove non-alphanumeric characters
    key = regexprep(normalizedInputs(idx), '[^a-z0-9_]', '');
    
    % Strip derived suffixes to map to base metric
    key = regexprep(key, '_(broad|broadband|avg|analyte|weighted|laser|approx)$', '');
    
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
