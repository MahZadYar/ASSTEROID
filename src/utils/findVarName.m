function idx = findVarName(varNames, pattern)
idx = find(contains(varNames, pattern, 'IgnoreCase', true), 1);
end