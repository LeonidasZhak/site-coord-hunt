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

#' Score each record that is not yet located.
#'
#' A coarse record is scored over its unit's candidate cells, each weighted by the
#' share of the polygon that falls in it. A narrowed record is scored over its marked
#' cells with the entomologist's weights, so marking cells shrinks the uncertainty.
#' `candidates`: table from build_candidates() (unit_id, cell_id, weight);
#' `scores`: SpatRaster from score_cells(); `states`: list from record_states().
#' One row per record: n_cells, max_shape, weighted mean_shape, range_shape,
#' min_mess, and pct_outside (weighted share of cells with MESS < 0).
record_summary <- function(candidates, scores, states) {
  recs <- states$records
  todo <- recs[recs$status != "located", , drop = FALSE]
  by_unit <- split(candidates[, c("cell_id", "weight")], candidates$unit_id)
  rows <- lapply(seq_len(nrow(todo)), function(k) {
    r <- todo[k, ]
    if (r$status == "narrowed") {
      cc <- states$cells[states$cells$record_id == r$record_id, , drop = FALSE]
    } else {
      cc <- if (is.na(r$unit_id)) NULL else by_unit[[r$unit_id]]
    }
    if (is.null(cc)) cc <- data.frame(cell_id = numeric(), weight = numeric())
    v <- if (nrow(cc)) terra::extract(scores, cc$cell_id) else data.frame(mess = numeric(), shape = numeric())
    w <- cc$weight
    ok <- stats::complete.cases(v)
    v <- v[ok, , drop = FALSE]; w <- w[ok]
    n <- nrow(v)
    data.frame(
      record_id = r$record_id, unit_id = r$unit_id, status = r$status, n_cells = n,
      max_shape   = if (n) max(v$shape) else NA_real_,
      mean_shape  = if (n) sum(w * v$shape) / sum(w) else NA_real_,
      range_shape = if (n) diff(range(v$shape)) else NA_real_,
      min_mess    = if (n) min(v$mess) else NA_real_,
      pct_outside = if (n) sum(w * (v$mess < 0)) / sum(w) * 100 else NA_real_,
      stringsAsFactors = FALSE)
  })
  if (length(rows) == 0) return(data.frame())
  do.call(rbind, rows)
}

#' Roll record scores up to the unit (what the work list is ordered by). A unit is as
#' valuable as its most valuable record. `records` is states$records; `units` is the
#' units table (for display names); the date span covers the unit's unlocated records.
unit_summary <- function(rec_sum, records, units) {
  if (nrow(rec_sum) == 0) return(data.frame())
  rs <- rec_sum[rec_sum$n_cells > 0 & !is.na(rec_sum$unit_id), , drop = FALSE]
  todo <- records[records$status != "located", , drop = FALSE]
  rows <- lapply(unique(rs$unit_id), function(u) {
    x <- rs[rs$unit_id == u, ]
    data.frame(
      unit_id     = u,
      unit_name   = units$unit_name[match(u, units$unit_id)],
      n_records   = nrow(x),
      n_narrowed  = sum(x$status == "narrowed"),
      dates       = date_span_label(todo$date[todo$unit_id %in% u]),
      n_cells     = max(x$n_cells),
      max_shape   = max(x$max_shape),
      mean_shape  = mean(x$mean_shape),
      range_shape = max(x$range_shape),
      min_mess    = min(x$min_mess),
      pct_outside = mean(x$pct_outside),
      stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}
