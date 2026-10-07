function canonicalOrder = detectCanonicalOrderFromHeader(headerLine, defaultRaw, canonical, tokenStarts)
numVars = numel(tokenStarts);
canonicalOrder = cell(1, numVars);
canonicalOrder(:) = {''};

if isempty(headerLine) || numVars == 0
    return;
end

aliasGroups = buildDefaultAliasGroups(defaultRaw);
headerLower = lower(headerLine);

for jj = 1:numel(aliasGroups)
    variants = aliasGroups{jj};
    bestPos = inf;
    for kk = 1:numel(variants)
        aliasLower = lower(variants{kk});
        if isempty(aliasLower)
            continue;
        end
        hit = strfind(headerLower, aliasLower);
        if ~isempty(hit)
            if hit(1) < bestPos
                bestPos = hit(1);
            end
        end
    end
    
    if isfinite(bestPos)
        % Find the closest tokenStart to this position
        [~, closestIdx] = min(abs(tokenStarts - bestPos));
        % Prevent overwriting if something even closer is already there
        % But for simplicity, just assign it (collisions are rare for valid aliases)
        canonicalOrder{closestIdx} = canonical{jj};
    end
end
end