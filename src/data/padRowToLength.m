function row = padRowToLength(row, targetLen)
row = double(row(:)');
if numel(row) < targetLen
    row(end+1:targetLen) = NaN;
else
    row = row(1:targetLen);
end
end