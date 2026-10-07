function seedTable = buildSeedTable(seeds)
%buildSeedTable Convert seed struct array to table format for localization workflow.
%
%   seedTable = buildSeedTable(seeds)
%
%   Input:
%       seeds - Struct array with fields P, R (nm), optional Tag.
%
%   Output:
%       seedTable - Table with columns CandidateIndex, P_um, R_um, Tag, GridValue.

    seeds = normalizeSeedInput(seeds);
    if isempty(seeds)
        seedTable = table();
        return;
    end

    N = numel(seeds);

    % Preallocate N×1 column vectors explicitly
    idxCol  = (1:N)';
    pUmCol  = NaN(N, 1);
    rUmCol  = NaN(N, 1);
    tagsCol = strings(N, 1);

    for k = 1:N
        s = seeds(k);
        p = double(s.P);
        r = double(s.R);
        pUmCol(k) = p(1) * 1e-3;
        rUmCol(k) = r(1) * 1e-3;
        t = string(s.Tag);
        if isempty(t) || strlength(t(1)) == 0
            tagsCol(k) = "Seed " + string(k);
        else
            tagsCol(k) = t(1);
        end
    end

    seedTable = table(idxCol, pUmCol, rUmCol, tagsCol, ...
        'VariableNames', {'CandidateIndex', 'P_um', 'R_um', 'Tag'});
    seedTable.GridValue = NaN(N, 1);
end
