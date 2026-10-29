function tf = isPhysicsSchemaModel(model)
%isPhysicsSchemaModel True if the model uses a physics feature schema.
%
%   Physics-schema models (v2_physics or v3_physics) carry
%   model.featureSchema (struct with Name, FeatureMean, FeatureStd) and
%   model.targetTransform (Mean, Std, LogMask). All other models are
%   treated as legacy (v1) models.
%
%   See also: physicsSchemaNames, buildPhysicsFeatures, ensureModelFlags

tf = isstruct(model) && isfield(model, "featureSchema") && isstruct(model.featureSchema) ...
    && isfield(model.featureSchema, "Name") ...
    && any(string(model.featureSchema.Name) == ["v2_physics", "v3_physics"]);
end
