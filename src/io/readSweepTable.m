function T = readSweepTable(filePath)
[~,~,ext] = fileparts(filePath);
switch lower(ext)
    case '.csv'
        opts = detectImportOptions(filePath, 'Delimiter', ';', 'DecimalSeparator', ',', ...
            'VariableNamingRule', 'preserve');
        opts = setvaropts(opts, opts.VariableNames, 'TreatAsMissing', {'', 'NaN'});
        T = readtable(filePath, opts);
    case {'.dat', '.txt'}
        T = readComsolDat(filePath);
    otherwise
        error('Unsupported sweep data file extension: %s', ext);
end
end