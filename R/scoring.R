# Novelty scoring: MESS and SHAPE of every mask cell against a reference set.
#
# `covs`  : multi-layer SpatRaster (the model mask; NA = outside mask)
# `ref_xy`: data.frame with lon/lat of the reference (precisely located) sites

#' Extract covariate values at reference-site locations, dropping sites that
#' fall outside the mask and duplicates within the same cell.
reference_table <- function(covs, ref_xy) {
  if (nrow(ref_xy) == 0) return(covs_df0(covs))
  v <- terra::extract(covs, as.matrix(ref_xy[, c("lon", "lat")]), cells = TRUE)
  v <- v[stats::complete.cases(v) & !duplicated(v$cell), , drop = FALSE]
  v
}

covs_df0 <- function(covs) {
  d <- as.data.frame(matrix(numeric(0), 0, terra::nlyr(covs) + 1))
  names(d) <- c("cell", names(covs))
  d
}

#' MESS (Elith et al. 2010) for each cell of `covs` against reference values.
#' Returns a SpatRaster with one layer, `mess`. Negative = at least one covariate
#' lies outside the range of the reference set.
mess_raster <- function(covs, ref_vals) {
  per_var <- lapply(names(covs), function(v) {
    ref <- sort(ref_vals[[v]])
    mn <- ref[1]; mx <- ref[length(ref)]
    x  <- terra::values(covs[[v]], mat = FALSE)
    # percentage of reference values strictly less than x (empirical CDF)
    pct <- findInterval(x, ref, left.open = TRUE) / length(ref) * 100
    ifelse(pct == 0,  (x - mn) / (mx - mn) * 100,
    ifelse(pct <= 50, 2 * pct,
    ifelse(pct < 100, 2 * (100 - pct),
                      (mx - x) / (mx - mn) * 100)))
  })
  terra::setValues(covs[[1]], do.call(pmin, per_var)) |> stats::setNames("mess")
}

#' SHAPE extrapolation (Velazco et al. 2023) via flexsdm::extra_eval.
#' Returns a one-layer SpatRaster, `shape`: distance from each cell to the
#' nearest reference site (Mahalanobis by default) expressed as a percentage of
#' the mean distance of reference sites to their own centroid. 0 = identical to
#' a reference site; values above 100 lie farther from the nearest reference
#' site than the reference cloud's typical spread. It is unbounded.
#'
#' We deliberately do not use flexsdm's `univar_comb` layer: in flexsdm 1.4.2
#' its codes are the reverse of its help text (2 = outside range in at least
#' one covariate, 1 = within range). "Outside range" comes from MESS instead.
shape_raster <- function(covs, ref_vals, metric = "mahalanobis") {
  train <- ref_vals[, names(covs), drop = FALSE]
  train$pr_ab <- 1
  res <- flexsdm::extra_eval(training_data = train, pr_ab = "pr_ab",
                             projection_data = covs, metric = metric,
                             univar_comb = FALSE)
  stats::setNames(res, "shape")
}

#' Score all mask cells: layers `mess` and `shape`. Needs at least `min_ref` reference cells.
score_cells <- function(covs, ref_xy, min_ref = 8, metric = "mahalanobis") {
  ref <- reference_table(covs, ref_xy)
  if (nrow(ref) < min_ref) {
    stop(sprintf("Need at least %d located sites inside the mask; have %d.",
                 min_ref, nrow(ref)), call. = FALSE)
  }
  c(mess_raster(covs, ref), shape_raster(covs, ref, metric))
}

#' Summarise cell scores over each coarse record's admin polygon.
#'
#' `admin` : sf polygons with admin_name
#' `scores`: SpatRaster from score_cells()
#' `records`: data.frame with record_id, admin_name, located (logical)
#' Returns one row per admin unit that has unlocated records.
summarise_units <- function(admin, scores, records) {
  todo <- records[!records$located, , drop = FALSE]
  units <- unique(todo$admin_name[!is.na(todo$admin_name)])
  rows <- lapply(units, function(u) {
    poly <- admin[admin$admin_name == u, ]
    if (nrow(poly) == 0) return(NULL)
    v <- terra::extract(scores, terra::vect(poly), ID = FALSE)
    v <- v[stats::complete.cases(v), , drop = FALSE]
    n <- nrow(v)
    data.frame(
      admin_name   = u,
      n_records    = sum(todo$admin_name == u, na.rm = TRUE),
      n_cells      = n,
      max_shape    = if (n) max(v$shape) else NA_real_,
      mean_shape   = if (n) mean(v$shape) else NA_real_,
      range_shape  = if (n) diff(range(v$shape)) else NA_real_,
      min_mess     = if (n) min(v$mess) else NA_real_,
      pct_outside  = if (n) mean(v$mess < 0) * 100 else NA_real_,
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  if (is.null(out)) return(data.frame())
  out[order(-out$max_shape), , drop = FALSE]
}
