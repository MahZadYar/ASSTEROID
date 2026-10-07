function mappedNames = mapHeadersToDefaults(rawNames, defaultRaw, canonical)
mappedNames = repmat({''}, size(rawNames));
if isempty(rawNames)
    return;
end

aliasGroups = buildDefaultAliasGroups(defaultRaw);

for ii = 1:numel(rawNames)
    candidate = strtrim(rawNames{ii});
    if isempty(candidate)
        continue;
    end
    for jj = 1:numel(aliasGroups)
        if any(strcmpi(candidate, aliasGroups{jj}))
            mappedNames{ii} = canonical{jj};
            break;
        end
    end
end
end