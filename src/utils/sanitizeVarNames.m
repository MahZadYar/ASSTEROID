function cleanNames = sanitizeVarNames(varNames)
if isstring(varNames)
    varNames = cellstr(varNames);
end
numNames = numel(varNames);
tokens = cell(numNames, 1);
for ii = 1:numNames
    name = varNames{ii};
    if isempty(name)
        tokens{ii} = sprintf('Var%d', ii);
        continue;
    end
    token = regexp(name, '^\S+', 'match', 'once');
    if isempty(token)
        tokens{ii} = sprintf('Var%d', ii);
    else
        tokens{ii} = token;
    end
end

valid = matlab.lang.makeValidName(tokens);
cleanNames = matlab.lang.makeUniqueStrings(valid, {}, namelengthmax);
end