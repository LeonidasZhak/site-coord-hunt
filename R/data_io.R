# The only file that reads or writes project data. Swap this for a database
# backend later without touching the app or scoring code.

CORRECTION_COLS <- c("record_id", "lon", "lat", "cell_id", "method",
                     "source", "confidence", "user", "timestamp")

load_inputs <- function(dir = "data") {
  list(
    covs    = terra::rast(file.path(dir, "covariates.tif")),
    admin   = sf::st_read(file.path(dir, "admin.gpkg"), quiet = TRUE),
    records = utils::read.csv(file.path(dir, "records.csv"),
                              stringsAsFactors = FALSE, na.strings = c("", "NA"))
  )
}

read_corrections <- function(dir = "data") {
  f <- file.path(dir, "corrections.csv")
  if (!file.exists(f)) {
    d <- as.data.frame(matrix(character(0), 0, length(CORRECTION_COLS)))
    names(d) <- CORRECTION_COLS
    return(d)
  }
  utils::read.csv(f, stringsAsFactors = FALSE, na.strings = c("", "NA"))
}

#' Append one geolocation action. The log is append-only so edits stay auditable;
#' a later row for the same record_id supersedes earlier ones.
append_correction <- function(row, dir = "data") {
  stopifnot(all(CORRECTION_COLS %in% names(row)))
  row <- row[, CORRECTION_COLS, drop = FALSE]
  f <- file.path(dir, "corrections.csv")
  utils::write.table(row, f, sep = ",", row.names = FALSE, na = "",
                     col.names = !file.exists(f), append = file.exists(f),
                     qmethod = "double")
  invisible(row)
}

#' Records with corrections applied (latest correction per record wins) and a
#' `located` flag: TRUE when coordinates fall inside a non-NA mask cell.
apply_corrections <- function(records, corrections, covs) {
  if (nrow(corrections) > 0) {
    last <- corrections[!duplicated(corrections$record_id, fromLast = TRUE), ]
    i <- match(last$record_id, records$record_id)
    ok <- !is.na(i)
    records$lon[i[ok]] <- last$lon[ok]
    records$lat[i[ok]] <- last$lat[ok]
  }
  records$located <- FALSE
  has_xy <- !is.na(records$lon) & !is.na(records$lat)
  if (any(has_xy)) {
    v <- terra::extract(covs[[1]], as.matrix(records[has_xy, c("lon", "lat")]))
    records$located[has_xy] <- !is.na(v[[1]])
  }
  records
}

#' Admin names in records that do not match any polygon (reported to the user,
#' never silently dropped).
unmatched_names <- function(records, admin) {
  nm <- unique(records$admin_name[!is.na(records$admin_name)])
  setdiff(nm, admin$admin_name)
}
