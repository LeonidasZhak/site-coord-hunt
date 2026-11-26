# Simulate a covariate stack, admin units and surveillance records.
# Run from the repo root:  Rscript data-raw/simulate_data.R
suppressPackageStartupMessages({
  library(terra)
  library(sf)
})
source("R/candidates.R")

set.seed(42)

# ---- model mask / covariates ------------------------------------------------
# 60 x 60 cells in a projected CRS-free lon/lat box; ~0.05 degree cells.
r <- rast(nrows = 60, ncols = 60, xmin = 30, xmax = 33, ymin = -3, ymax = 0,
          crs = "EPSG:4326")

smooth_field <- function(r, sd_cells, seed) {
  set.seed(seed)
  f <- setValues(r, rnorm(ncell(r)))
  w <- focalMat(f, sd_cells * res(f)[1], type = "Gauss")
  f <- focal(f, w = w, fun = "sum", na.rm = TRUE, expand = TRUE)
  (f - global(f, "mean")[[1]]) / global(f, "sd")[[1]]
}

xy   <- crds(r, df = TRUE)
elev <- smooth_field(r, 6, 1)
temp <- -0.8 * elev + 0.4 * smooth_field(r, 3, 2)   # temperature falls with elevation
prec <- 0.5 * smooth_field(r, 5, 3) + setValues(r, 0.3 * (xy$x - 31.5))
cov  <- c(elev, temp, prec)
cov  <- scale(cov)
names(cov) <- c("elevation", "temperature", "precipitation")

# Irregular mask: remove a "lake" and the corners.
mask <- rep(1, ncell(r))
d_lake <- sqrt((xy$x - 32.2)^2 + (xy$y + 1.0)^2)
mask[d_lake < 0.35] <- NA
mask[sqrt((xy$x - 30)^2 + (xy$y - 0)^2) < 0.4] <- NA
cov <- mask(cov, setValues(r, mask))

# ---- admin units ------------------------------------------------------------
# A 6 x 6 block of admin units, cut to the mask extent.
adm_grid <- st_make_grid(st_as_sfc(st_bbox(c(xmin = 30, xmax = 33, ymin = -3, ymax = 0),
                                           crs = 4326)), n = c(6, 6))
admin <- st_sf(admin_id = seq_along(adm_grid),
               admin_name = sprintf("Parish %02d", seq_along(adm_grid)),
               geometry = adm_grid)

# ---- records ----------------------------------------------------------------
# Precisely located sites are drawn preferentially from common conditions
# (near the mean of elevation and temperature), so admin units covering extreme
# conditions are unrepresented in the reference set and scoring has something
# to find.
cells <- as.data.frame(cov, xy = TRUE, cells = TRUE, na.rm = TRUE)
p_loc <- dnorm(cells$elevation, 0, 0.7) * dnorm(cells$temperature, 0, 0.9)
loc_idx <- sample(nrow(cells), 45, prob = p_loc)
located <- data.frame(
  record_id = sprintf("R%03d", 1:45),
  lon = cells$x[loc_idx] + runif(45, -0.02, 0.02),
  lat = cells$y[loc_idx] + runif(45, -0.02, 0.02)
)

# Coarse records: sample cells uniformly within random admin units, but record
# only the unit name.
n_coarse <- 40
adm_sample <- sample(admin$admin_id, n_coarse, replace = TRUE)
coarse <- data.frame(
  record_id = sprintf("R%03d", 46:(45 + n_coarse)),
  admin_name = admin$admin_name[adm_sample],
  lon = NA_real_, lat = NA_real_
)

records <- rbind(
  cbind(located[, "record_id", drop = FALSE],
        admin_name = NA_character_, located[, c("lon", "lat")]),
  coarse
)
# Some located records also carry an admin name, as in real data.
pts <- st_as_sf(records[!is.na(records$lon), ], coords = c("lon", "lat"),
                crs = 4326, remove = FALSE)
nm  <- admin$admin_name[st_intersects(pts, admin, sparse = FALSE) |> apply(1, which.max)]
records$admin_name[!is.na(records$lon)] <- nm
records$n_specimens <- sample(1:20, nrow(records), replace = TRUE)

# Dates, with the mix of precision real records have: mostly full dates, some
# month-only or year-only, a few missing. Separate seeds keep everything above
# identical to earlier versions of this script.
make_dates <- function(n) {
  d    <- as.Date("2015-01-01") + sample(0:(365 * 9 - 1), n, replace = TRUE)
  prec <- sample(c("day", "month", "year", "none"), n, replace = TRUE,
                 prob = c(0.6, 0.25, 0.1, 0.05))
  ifelse(prec == "day", format(d),
  ifelse(prec == "month", format(d, "%Y-%m"),
  ifelse(prec == "year", format(d, "%Y"), NA_character_)))
}
set.seed(7)
records$date <- make_dates(nrow(records))

# Records are attributed to a unit by id. The parishes are the units so far.
records$unit_id <- sprintf("parish:%02d", match(records$admin_name, admin$admin_name))
records$admin_name <- NULL

# ---- a second layer of units that overlaps the first -----------------------
# Eight facility catchments, squares that do not line up with the model grid and that
# sit inside parishes (so a cell can belong to a facility and to a parish). Two are
# smaller than a cell, so each lies within a single cell; they are located without
# anyone having to mark them. Facility records are added after the others, with their
# own seeds, so nothing above changes.
set.seed(11)
fac_w  <- c(0.03, 0.03, 0.12, 0.12, 0.12, 0.30, 0.30, 0.30)
fac_c  <- sample(nrow(cells), length(fac_w))
fac_o  <- ifelse(fac_w < 0.05, 0.008, 0.02)
fac_x  <- cells$x[fac_c] + runif(length(fac_w), -1, 1) * fac_o
fac_y  <- cells$y[fac_c] + runif(length(fac_w), -1, 1) * fac_o
square <- function(x, y, w) st_polygon(list(rbind(c(x - w/2, y - w/2), c(x + w/2, y - w/2),
                                                  c(x + w/2, y + w/2), c(x - w/2, y + w/2),
                                                  c(x - w/2, y - w/2))))
facilities <- st_sf(unit_code = sprintf("F%02d", seq_along(fac_w)),
                    unit_name = sprintf("Facility F%02d", seq_along(fac_w)),
                    geometry = st_sfc(Map(square, fac_x, fac_y, fac_w), crs = 4326))
fac_n <- c(2, 1, 2, 2, 1, 3, 2, 2)                     # coarse records per facility
set.seed(13)
fac_records <- data.frame(
  record_id   = sprintf("R%03d", nrow(records) + seq_len(sum(fac_n))),
  unit_id     = rep(sprintf("facility:F%02d", seq_along(fac_n)), fac_n),
  lon = NA_real_, lat = NA_real_,
  n_specimens = sample(1:20, sum(fac_n), replace = TRUE),
  date        = make_dates(sum(fac_n)))
records <- rbind(records[, c("record_id", "unit_id", "lon", "lat", "n_specimens", "date")], fac_records)

# ---- write ------------------------------------------------------------------
dir.create("data", showWarnings = FALSE)
writeRaster(cov, "data/covariates.tif", overwrite = TRUE)
write.csv(records, "data/records.csv", row.names = FALSE, na = "")
message("Wrote data/covariates.tif, data/records.csv")

# Convert the polygon layers to candidate cells, as would be done for real data.
parishes <- st_sf(unit_code = sprintf("%02d", admin$admin_id), unit_name = admin$admin_name,
                  geometry = st_geometry(admin))
write_candidate_files(
  list(list(polygons = parishes,   id_col = "unit_code", name_col = "unit_name", prefix = "parish"),
       list(polygons = facilities, id_col = "unit_code", name_col = "unit_name", prefix = "facility")),
  cov, "data")
