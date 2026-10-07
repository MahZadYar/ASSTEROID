function idx = findExistingRows(dataStruct, periodVal, radiusVal)
idx = [];
if isempty(dataStruct) || ~isstruct(dataStruct)
    return;
end
periodVals = extractGeometryField(dataStruct, {'period','p'});
radiusVals = extractGeometryField(dataStruct, {'radius','particle_r','r'});
if isempty(periodVals) || isempty(radiusVals)
    return;
end
finitePeriod = periodVals(isfinite(periodVals));
finiteRadius = radiusVals(isfinite(radiusVals));
if isempty(finitePeriod) || isempty(finiteRadius)
    return;
end
TolP = max(1e-12, eps(max(abs(finitePeriod))));
TolR = max(1e-12, eps(max(abs(finiteRadius))));
idx = find(abs(periodVals - double(periodVal)) <= TolP & abs(radiusVals - double(radiusVal)) <= TolR);
end