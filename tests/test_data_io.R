# Run from repo root: Rscript tests/test_data_io.R
suppressPackageStartupMessages({library(terra); library(sf)})
source("R/scoring.R"); source("R/data_io.R")
chk <- function(cond, msg) if (!isTRUE(cond)) stop(msg, call. = FALSE)

inp <- load_inputs("data")
tmp <- tempfile(); dir.create(tmp)
r0 <- apply_corrections(inp$records, read_corrections(tmp), inp$covs)
chk(sum(r0$located) == 45, paste("expected 45 located, got", sum(r0$located)))
chk(length(unmatched_names(inp$records, inp$admin)) == 0, "unexpected unmatched names")

# append two corrections for the same record: the later one must win
todo <- r0$record_id[!r0$located][1]
mk <- function(lon, lat) data.frame(record_id = todo, lon = lon, lat = lat, cell_id = 1,
  method = "point", source = "GPS", confidence = "high", user = "t", timestamp = "x")
append_correction(mk(31.1, -1.1), tmp); append_correction(mk(31.5, -1.5), tmp)
r1 <- apply_corrections(inp$records, read_corrections(tmp), inp$covs)
chk(sum(r1$located) == 46, "correction not counted as located")
chk(abs(r1$lon[r1$record_id == todo] - 31.5) < 1e-9, "latest correction should win")

# a correction outside the mask must not count as located
tmp2 <- tempfile(); dir.create(tmp2)
append_correction(mk(10, 10), tmp2)
r2 <- apply_corrections(inp$records, read_corrections(tmp2), inp$covs)
chk(sum(r2$located) == 45, "outside-mask correction counted as located")

# original file untouched
chk(is.na(inp$records$lon[inp$records$record_id == todo]), "original records mutated")

# ranking on simulated data
sc <- score_cells(inp$covs, r0[r0$located, c("lon", "lat")])
u <- summarise_units(inp$admin, sc, r0)
print(head(u, 6), digits = 3)
chk(nrow(u) > 0 && !is.unsorted(rev(u$max_shape)), "units not sorted by max_shape")
cat("All data_io tests passed\n")
