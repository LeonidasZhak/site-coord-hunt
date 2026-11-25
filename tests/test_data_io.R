# Run from repo root: Rscript tests/test_data_io.R
suppressPackageStartupMessages({library(terra); library(sf)})
source("R/dates.R"); source("R/scoring.R"); source("R/data_io.R")
chk <- function(cond, msg) if (!isTRUE(cond)) stop(msg, call. = FALSE)

inp <- load_inputs("data")
covs <- inp$covs
st0 <- record_states(inp$records, empty_corrections(), covs)
chk(sum(st0$records$status == "located") == 45, "expected 45 located")
chk(sum(st0$records$status == "coarse") == 40, "expected 40 coarse")
chk(length(unmatched_names(inp$records, inp$admin)) == 0, "unexpected unmatched names")

coarse <- st0$records$record_id[st0$records$status == "coarse"]
a <- coarse[1]; b <- coarse[2]
cell_xy <- function(cell) { xy <- xyFromCell(covs[[1]], cell); list(lon = xy[1], lat = xy[2]) }
act <- function(id, cells, w, mode = "manual", method = "cells") {
  xy <- lapply(cells, cell_xy)
  data.frame(action_id = new_action_id(), record_id = id, cell_id = cells,
             lon = sapply(xy, `[[`, "lon"), lat = sapply(xy, `[[`, "lat"),
             weight = w, weight_mode = mode, method = method, source = "t",
             confidence = "high", user = "t", timestamp = "x")
}
dir <- tempfile(); dir.create(dir)

# several cells: narrowed until one cell is heavy enough
valid <- which(!is.na(values(covs[[1]], mat = FALSE)))
cs <- valid[c(100, 500, 900)]
append_correction(act(a, cs[1:2], c(0.5, 0.5), "even"), dir)
st <- record_states(inp$records, read_corrections(dir), covs)
chk(st$records$status[st$records$record_id == a] == "narrowed", "50/50 should be narrowed")
chk(nrow(st$cells) == 2 && all(st$cells$weight == 0.5), "marked cells not kept")

append_correction(act(b, cs[1:2], c(0.85, 0.15)), dir)
st <- record_states(inp$records, read_corrections(dir), covs, located_share = 0.8)
rb <- st$records[st$records$record_id == b, ]
chk(rb$status == "located", "85% on one cell should count as located at 0.8")
chk(isTRUE(all.equal(c(rb$lon, rb$lat), unlist(cell_xy(cs[1])), check.attributes = FALSE)),
    "located record should use the heaviest cell")
st9 <- record_states(inp$records, read_corrections(dir), covs, located_share = 0.9)
chk(st9$records$status[st9$records$record_id == b] == "narrowed", "threshold must be adjustable")

# a later save replaces the earlier one in full, in both directions
append_correction(act(a, cs[3], 1, "even", "cell"), dir)
st <- record_states(inp$records, read_corrections(dir), covs)
chk(st$records$status[st$records$record_id == a] == "located", "single cell should replace narrowed")
chk(!(a %in% st$cells$record_id), "old marked cells should be gone")
append_correction(act(a, cs[1:3], rep(1/3, 3), "even"), dir)
st <- record_states(inp$records, read_corrections(dir), covs)
chk(st$records$status[st$records$record_id == a] == "narrowed", "narrowing again should replace located")
chk(sum(st$cells$record_id == a) == 3, "expected 3 marked cells")

# input validation and the original data
err <- tryCatch(append_correction(act(a, cs[1:2], c(0.5, 0.6)), dir), error = function(e) e)
chk(inherits(err, "error"), "weights that do not sum to 1 must be refused")
chk(is.na(inp$records$lon[inp$records$record_id == a]), "original records mutated")

# files from the first prototype (no action id or weight) still load
old <- tempfile(); dir.create(old)
writeLines(c('"record_id","lon","lat","cell_id","method","source","confidence","user","timestamp"',
             sprintf('"%s",%f,%f,%d,"cell","x","high","t","y"', a, cell_xy(cs[1])$lon, cell_xy(cs[1])$lat, cs[1])),
           file.path(old, "corrections.csv"))
lc <- read_corrections(old)
chk(lc$weight == 1 && nzchar(lc$action_id), "legacy corrections not upgraded")
chk(record_states(inp$records, lc, covs)$records$status[inp$records$record_id == a] == "located", "legacy row should locate")

# flags: flag, dismiss, flag again
fdir <- tempfile(); dir.create(fdir)
chk(length(current_flags(read_flags(fdir))) == 0, "no flags at start")
fl <- function(action, id) data.frame(action = action, record_id = id, user = "u", timestamp = "x", note = "")
append_flag(fl("flag", "R001"), fdir); append_flag(fl("flag", "R002"), fdir)
chk(setequal(current_flags(read_flags(fdir)), c("R001", "R002")), "two flags expected")
append_flag(fl("dismiss", "R001"), fdir)
chk(identical(current_flags(read_flags(fdir)), "R002"), "dismiss should clear a flag")
append_flag(fl("flag", "R001"), fdir)
chk(setequal(current_flags(read_flags(fdir)), c("R001", "R002")), "a new flag after dismissal counts")
chk(nrow(reference_xy(st0, c("R001", "R002"), TRUE)) == 43, "flagged sites should leave the reference set")
chk(nrow(reference_xy(st0, c("R001", "R002"), FALSE)) == 45, "exclusion must be optional")
chk(nrow(reference_xy(st0, character(0), TRUE)) == 45, "no flags, nothing excluded")

# ranking: narrowed records are scored over their marked cells only, weighted
st <- record_states(inp$records, read_corrections(dir), covs, located_share = 0.9)
sc <- score_cells(covs, reference_xy(st, character(0)))
rs <- record_summary(inp$admin, sc, st)
rb <- rs[rs$record_id == b, ]
cells_b <- st$cells[st$cells$record_id == b, ]
direct <- terra::extract(sc, cells_b$cell_id)
chk(rb$n_cells == 2, "narrowed record should be scored over its 2 marked cells")
chk(isTRUE(all.equal(rb$mean_shape, sum(cells_b$weight * direct$shape))), "mean_shape should be the weighted mean")
chk(isTRUE(all.equal(rb$max_shape, max(direct$shape))), "max_shape over marked cells")
chk(rs$n_cells[rs$record_id == coarse[3]] == 100, "coarse record scored over the whole polygon")
chk(!any(rs$record_id %in% st$records$record_id[st$records$status == "located"]), "located records must not be ranked")

u <- unit_summary(rs, st$records)
chk(all(nzchar(u$dates)), "every location should have a date label")
chk(sum(u$n_records) == sum(st$records$status != "located"), "unit record counts should add up")
cat("All data_io tests passed\n")
