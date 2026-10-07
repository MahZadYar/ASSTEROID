function [nVals, kVals] = evalRefractiveIndex(ri, lambdaUm)
%evalRefractiveIndex Evaluate an RI struct at wavelengths given in µm.
%
%   [n, k] = evalRefractiveIndex(ri, lambdaUm)
%
%   Accepts RI structs whose interpolant grid is in µm (load_gold_refractive_index,
%   getDefaultRefractiveIndex(WavelengthUnit="um")) or in nm (legacy
%   getDefaultRefractiveIndex default). The grid unit is inferred from
%   ri.lambda (values > 50 imply nm) so callers always pass µm.

lambdaUm = double(lambdaUm);
query = lambdaUm;
if isfield(ri, "lambda") && ~isempty(ri.lambda) && max(double(ri.lambda(:))) > 50
    query = lambdaUm * 1e3;
end
nVals = double(ri.nFunc(query));
kVals = double(ri.kFunc(query));
nVals = reshape(nVals, size(lambdaUm));
kVals = reshape(kVals, size(lambdaUm));
end
