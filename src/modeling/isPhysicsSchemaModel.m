function tf = isPhysicsSchemaModel(model)
%isPhysicsSchemaModel True if the model uses the v2 physics feature schema.
%
%   v2 models carry model.featureSchema (struct with Name="v2_physics",
%   FeatureMean, FeatureStd) and model.targetTransform (Mean, Std, Log1p).
%   All other models are treated as legacy (v1) models.

tf = isstruct(model) && isfield(model, "featureSchema") && isstruct(model.featureSchema) ...
    && isfield(model.featureSchema, "Name") && string(model.featureSchema.Name) == "v2_physics";
end
