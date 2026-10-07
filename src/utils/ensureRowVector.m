function vec = ensureRowVector(val)
if isnumeric(val) || islogical(val)
    vec = double(val(:)');
elseif isstring(val)
    vec = double(str2double(val(:)'));
elseif ischar(val)
    vec = double(str2double(string(val(:)')));
else
    vec = [];
end
end