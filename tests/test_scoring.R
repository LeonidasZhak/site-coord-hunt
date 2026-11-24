# Run from repo root: Rscript tests/test_scoring.R
suppressPackageStartupMessages(library(terra))
source("R/scoring.R")
stopifnot_msg <- function(cond, msg) if (!isTRUE(cond)) stop(msg, call. = FALSE)

# --- MESS on a toy 1-covariate case, checked against the Elith et al. formula
r <- rast(nrows = 1, ncols = 5, xmin = 0, xmax = 5, ymin = 0, ymax = 1)
values(r) <- c(-5, 0, 5, 10, 25)
names(r) <- "a"
ref <- data.frame(a = 0:10)            # min 0, max 10, n = 11
m <- values(mess_raster(r, ref))[, 1]
# x = -5 : below min  -> (-5 - 0)/10*100 = -50
# x =  0 : pct 0 (nothing below) -> (0 - 0)/10*100 = 0
# x =  5 : 5 of 11 below = 45.45 -> 2*45.45 = 90.9
# x = 10 : 10 of 11 below = 90.9 -> 2*(100-90.9) = 18.2
# x = 25 : 11 of 11 below = 100 -> (10-25)/10*100 = -150
expected <- c(-50, 0, 2 * 5 / 11 * 100, 2 * (100 - 10 / 11 * 100), -150)
stopifnot_msg(isTRUE(all.equal(m, expected)), paste("MESS mismatch:", toString(m)))

# --- MESS takes the minimum across covariates
r2 <- c(r, r); names(r2) <- c("a", "b")
ref2 <- data.frame(a = 0:10, b = 0:10)
values(r2[["b"]]) <- c(5, 5, 5, 5, 5)
m2 <- values(mess_raster(r2, ref2))[, 1]
stopifnot_msg(isTRUE(all.equal(m2, pmin(expected, 2 * 5 / 11 * 100))), "MESS min-over-covariates failed")

# --- SHAPE: an outlying cell scores higher than a typical one
set.seed(1)
cov <- rast(nrows = 20, ncols = 20, nlyrs = 2, xmin = 0, xmax = 1, ymin = 0, ymax = 1)
values(cov) <- cbind(rnorm(400), rnorm(400)); names(cov) <- c("a", "b")
cov[1] <- c(8, 8)                      # extreme cell
ref_xy <- as.data.frame(crds(cov)[sample(2:400, 40), ]); names(ref_xy) <- c("lon", "lat")
sc <- score_cells(cov, ref_xy)
stopifnot_msg(identical(names(sc), c("mess", "shape")), "layers missing")
stopifnot_msg(values(sc$shape)[1] == max(values(sc$shape), na.rm = TRUE), "outlier not top SHAPE")
stopifnot_msg(values(sc$mess)[1] < 0, "outlier should be outside MESS range")

# --- too few reference sites is an error, not a silent result
err <- tryCatch(score_cells(cov, ref_xy[1:3, ]), error = function(e) e)
stopifnot_msg(inherits(err, "error"), "expected error for too few reference sites")
cat("All scoring tests passed\n")
