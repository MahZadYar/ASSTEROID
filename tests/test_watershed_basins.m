%% test_watershed_basins.m
% Unit tests for detect_watershed_basins and assignSeedsToBasins on a
% synthetic surface: two separated peaks plus a shoulder peak on the flank
% of the higher one (the "H on G's flank" case), and a sub-threshold ripple.

setup_project;
fprintf("=== Starting test_watershed_basins ===\n");

pUm = linspace(0.4, 1.4, 201);          % 5 nm step
rUm = linspace(0.05, 0.45, 81);
[Pm, Rm] = meshgrid(pUm, rUm);
g = @(p0, r0, a, s) a * exp(-((Pm - p0).^2 + (Rm - r0).^2) / (2 * s^2));
F = g(1.10, 0.30, 100, 0.08) ...        % main peak
  + g(1.25, 0.38, 35, 0.025) ...         % shoulder on the main peak's flank
  + g(0.60, 0.15, 60, 0.06) ...          % separate peak
  + 0.02 * sin(40 * Pm);                 % low ripple (< 1 % of range)

%% 1. Basin count and ordering
[T, bmap] = detect_watershed_basins(F, pUm, rUm, Sensitivity = 0.01);
assert(height(T) == 3, "Expected 3 basins (main, shoulder, separate); got %d.", height(T));
assert(issorted(T.GridValue, "descend"), "Candidates must be sorted by peak value.");
assert(all(T.Tag == ["A"; "B"; "C"]), "Tags must be A, B, C.");
fprintf("  V 3 basins detected, ripple merged.\n");

%% 2. Shoulder maximum is preserved and located on the flank
[~, iShoulder] = min(hypot(T.P_um - 1.25, T.R_um - 0.38));
assert(hypot(T.P_um(iShoulder) - 1.25, T.R_um(iShoulder) - 0.38) < 0.02, "Shoulder peak not resolved.");
assert(T.Depth(iShoulder) > 0, "Shoulder depth must be positive.");
fprintf("  V Shoulder peak preserved (depth %.2f).\n", T.Depth(iShoulder));

%% 3. Higher sensitivity merges the shoulder into its parent
T2 = detect_watershed_basins(F, pUm, rUm, Sensitivity = 0.5);
assert(height(T2) < height(T), "Large sensitivity must merge the shoulder.");
fprintf("  V Sensitivity 50%% merges shallow peaks (%d basins).\n", height(T2));

%% 4. Territories tile the domain (no ridge pixels left unassigned)
assert(all(bmap.labels(:) > 0), "Every finite cell must belong to a basin.");
assert(numel(bmap.polygons) == height(T), "One outline polygon per listed basin.");
fprintf("  V Territories tile the domain.\n");

%% 5. Seed lookup
ids = assignSeedsToBasins(bmap, T.P_um * 1e3, T.R_um * 1e3);
assert(isequal(ids, T.BasinId), "Each peak must map to its own basin.");
assert(assignSeedsToBasins(bmap, 2000, 100) == 0, "Points outside the grid must return 0.");
fprintf("  V assignSeedsToBasins maps peaks and rejects out-of-range points.\n");

%% 6. Ratio mask: cells above r/p limit excluded, peaks there not reported
[T3, bmap3] = detect_watershed_basins(F, pUm, rUm, Sensitivity = 0.01, RatioLimit = [0 0.25]);
assert(all(T3.Ratio <= 0.25 + 1e-12), "Peaks must respect the ratio window.");
assert(all(bmap3.labels(Rm ./ Pm > 0.25 + 1e-9) == 0), "Masked cells must be unlabelled.");
fprintf("  V Ratio window respected (%d basins).\n", height(T3));

%% 7. Flat or empty input
[T4, bmap4] = detect_watershed_basins(ones(size(F)), pUm, rUm);
assert(height(T4) == 0 && all(bmap4.labels(:) == 0), "Flat surface must yield no basins.");
fprintf("  V Flat surface yields no basins.\n");

fprintf("=== test_watershed_basins PASSED ===\n");
