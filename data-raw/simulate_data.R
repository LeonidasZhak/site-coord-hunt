# Simulate a covariate stack, admin units and surveillance records.
# Run from the repo root:  Rscript data-raw/simulate_data.R
suppressPackageStartupMessages({
  library(terra)
  library(sf)
})

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

# ---- write ------------------------------------------------------------------
dir.create("data", showWarnings = FALSE)
writeRaster(cov, "data/covariates.tif", overwrite = TRUE)
st_write(admin, "data/admin.gpkg", delete_dsn = TRUE, quiet = TRUE)
write.csv(records, "data/records.csv", row.names = FALSE, na = "")
message("Wrote data/covariates.tif, data/admin.gpkg, data/records.csv")
