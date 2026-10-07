function S = normalizeGeometryFields(S)
if isempty(S) || ~isstruct(S)
    return;
end
S = ensureFieldFromSources(S, 'period', {'p'});
S = ensureFieldFromSources(S, 'radius', {'r','particle_r'});
legacyFields = intersect(fieldnames(S), {'p','r','particle_r'});
if ~isempty(legacyFields)
    S = rmfield(S, legacyFields);
end
end