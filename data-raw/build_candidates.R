# Convert approximate locations (polygon layers) to the candidate-cell files the app reads.
#
# Edit the settings below, then run from the repo root:  Rscript data-raw/build_candidates.R
#
# Writes into `out_dir`:
#   candidates.csv  unit_id, cell_id, weight   which mask cells each unit could be in, and how likely
#   units.csv       unit_id, unit_name, layer, n_cells, mask_share
#   admin.gpkg      the unit outlines, with unit_id, for drawing on the map
#
# Rules (see DESIGN.md, "Converting polygons to cells"):
#  - weight = the share of the polygon's area that falls in the cell, i.e. uniform within
#    the polygon, normalised over mask cells so each unit sums to 1;
#  - layers may overlap (a facility catchment inside a parish); a cell can belong to many units;
#  - `prefix` makes ids unique across layers ("parish:7", "facility:7");
#  - units that cannot be converted properly are printed, never dropped silently.
# Records then point at a unit with `unit_id` in records.csv (or, where only names are
# available, with admin_name, optionally with unit_layer to separate same-named units).

suppressPackageStartupMessages({library(terra); library(sf)})
source("R/candidates.R")

if (!exists("mask_path")) mask_path <- "data/covariates.tif"   # the fixed project mask
if (!exists("out_dir"))   out_dir   <- "data"
if (!exists("layers")) {
  layers <- list(
    list(file = "path/to/parishes.gpkg",            id_col = "PARISH_ID", name_col = "PARISH_NAME",   prefix = "parish"),
    list(file = "path/to/facility_catchments.gpkg", id_col = "FAC_ID",    name_col = "FACILITY_NAME", prefix = "facility")
  )
}
missing <- Filter(function(l) !file.exists(l$file), layers)
if (length(missing)) stop("Edit `layers` in data-raw/build_candidates.R first. Not found: ",
                          paste(vapply(missing, `[[`, "", "file"), collapse = ", "), call. = FALSE)

mask <- rast(mask_path)
polys <- lapply(layers, function(l) list(polygons = st_read(l$file, quiet = TRUE),
                                         id_col = l$id_col, name_col = l$name_col, prefix = l$prefix))
write_candidate_files(polys, mask, out_dir)
