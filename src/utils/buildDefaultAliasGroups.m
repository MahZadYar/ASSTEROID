function aliasGroups = buildDefaultAliasGroups(defaultRaw)
aliasGroups = cell(size(defaultRaw));
for jj = 1:numel(defaultRaw)
    entry = strtrim(defaultRaw{jj});
    parts = strsplit(entry, ',');
    parts = cellfun(@(s) strtrim(s), parts, 'UniformOutput', false);
    combined = [{entry}, parts(:)'];
    combined = combined(~cellfun(@isempty, combined));
    aliasGroups{jj} = unique(combined, 'stable');
end
end