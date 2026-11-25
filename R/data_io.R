# The only file that reads or writes project data. Swap this for a database
# backend later without touching the app or scoring code.

CORRECTION_COLS <- c("action_id", "record_id", "cell_id", "lon", "lat", "weight",
                     "weight_mode", "method", "source", "confidence", "user",
                     "timestamp")
FLAG_COLS <- c("action", "record_id", "user", "timestamp", "note")

# ---- inputs -----------------------------------------------------------------

load_inputs <- function(dir = "data") {
  records <- utils::read.csv(
    file.path(dir, "records.csv"), stringsAsFactors = FALSE,
    na.strings = c("", "NA"),
    colClasses = c(record_id = "character", admin_name = "character", date = "character"))
  if (is.null(records$date)) records$date <- NA_character_
  list(
    covs    = terra::rast(file.path(dir, "covariates.tif")),
    admin   = sf::st_read(file.path(dir, "admin.gpkg"), quiet = TRUE),
    records = records
  )
}

# ---- corrections: one row per marked cell, grouped by action_id -------------

empty_corrections <- function() {
  data.frame(action_id = character(), record_id = character(), cell_id = numeric(),
             lon = numeric(), lat = numeric(), weight = numeric(),
             weight_mode = character(), method = character(), source = character(),
             confidence = character(), user = character(), timestamp = character(),
             stringsAsFactors = FALSE)
}

new_action_id <- function() {
  sprintf("%s-%04d", format(Sys.time(), "%Y%m%dT%H%M%S"), sample.int(9999, 1))
}

read_corrections <- function(dir = "data") {
  f <- file.path(dir, "corrections.csv")
  if (!file.exists(f)) return(empty_corrections())
  cls <- c(record_id = "character", action_id = "character")
  cls <- cls[names(cls) %in% names(utils::read.csv(f, nrows = 0))]
  d <- utils::read.csv(f, stringsAsFactors = FALSE, na.strings = c("", "NA"), colClasses = cls)
  # Files written by the first prototype have one row per record and no action
  # id or weight: each row is its own single-cell action.
  if (is.null(d$action_id)) d$action_id <- paste0("legacy-", seq_len(nrow(d)))
  if (is.null(d$weight)) d$weight <- 1
  if (is.null(d$weight_mode)) d$weight_mode <- "even"
  for (col in setdiff(CORRECTION_COLS, names(d))) d[[col]] <- NA
  d[, CORRECTION_COLS, drop = FALSE]
}

#' Append one save (one action): one row per marked cell. Weights are
#' proportions and must sum to 1.
append_correction <- function(rows, dir = "data") {
  stopifnot(all(CORRECTION_COLS %in% names(rows)), nrow(rows) >= 1,
            length(unique(rows$action_id)) == 1,
            all(rows$weight > 0), abs(sum(rows$weight) - 1) < 1e-6)
  rows <- rows[, CORRECTION_COLS, drop = FALSE]
  f <- file.path(dir, "corrections.csv")
  utils::write.table(rows, f, sep = ",", row.names = FALSE, na = "",
                     col.names = !file.exists(f), append = file.exists(f),
                     qmethod = "double")
  invisible(rows)
}

#' Rows of the most recent action for each record. The log is append-only, so
#' "latest" is the last action for that record in file order.
latest_action_rows <- function(corrections) {
  if (nrow(corrections) == 0) return(corrections)
  last_id <- tapply(corrections$action_id, corrections$record_id, function(a) a[length(a)])
  corrections[paste(corrections$record_id, corrections$action_id) %in%
                paste(names(last_id), last_id), , drop = FALSE]
}

# ---- flags: located sites flagged as possibly wrong -------------------------

empty_flags <- function() {
  data.frame(action = character(), record_id = character(), user = character(),
             timestamp = character(), note = character(), stringsAsFactors = FALSE)
}

read_flags <- function(dir = "data") {
  f <- file.path(dir, "flags.csv")
  if (!file.exists(f)) return(empty_flags())
  d <- utils::read.csv(f, stringsAsFactors = FALSE, na.strings = c("", "NA"),
                       colClasses = c(record_id = "character", note = "character"))
  d[, FLAG_COLS, drop = FALSE]
}

#' Append a flag (action = "flag", by an entomologist) or a dismissal
#' (action = "dismiss", by a modeller). Flags never change a record's location.
append_flag <- function(row, dir = "data") {
  stopifnot(all(FLAG_COLS %in% names(row)), row$action %in% c("flag", "dismiss"))
  row <- row[, FLAG_COLS, drop = FALSE]
  f <- file.path(dir, "flags.csv")
  utils::write.table(row, f, sep = ",", row.names = FALSE, na = "",
                     col.names = !file.exists(f), append = file.exists(f),
                     qmethod = "double")
  invisible(row)
}

#' Record ids whose latest flag action is "flag" (not since dismissed).
current_flags <- function(flags) {
  if (nrow(flags) == 0) return(character(0))
  last <- tapply(flags$action, flags$record_id, function(a) a[length(a)])
  names(last)[last == "flag"]
}

# ---- record states ----------------------------------------------------------

#' Work out what is known about every record.
#'
#' status: "located"  - one location inside the mask (a cell or a point), or a
#'                      marked-cell set where one cell holds at least
#'                      `located_share` of the weight (that cell is used);
#'         "narrowed" - several marked cells, none heavy enough;
#'         "coarse"   - only the location ID is known.
#' Returns list(records = records plus `status` and the effective lon/lat,
#'              cells   = marked cells of narrowed records with weights).
record_states <- function(records, corrections, covs, located_share = 0.8) {
  records$status <- "coarse"
  has_xy <- !is.na(records$lon) & !is.na(records$lat)
  if (any(has_xy)) {
    v <- terra::extract(covs[[1]], as.matrix(records[has_xy, c("lon", "lat")]))
    records$status[has_xy][!is.na(v[[1]])] <- "located"
  }
  cells <- data.frame(record_id = character(), cell_id = numeric(),
                      lon = numeric(), lat = numeric(), weight = numeric(),
                      stringsAsFactors = FALSE)
  last <- latest_action_rows(corrections)
  for (id in unique(last$record_id)) {
    i <- match(id, records$record_id)
    if (is.na(i)) next
    r <- last[last$record_id == id & !is.na(last$cell_id), , drop = FALSE]
    if (nrow(r) == 0) next
    heavy <- which.max(r$weight)
    if (nrow(r) == 1 || r$weight[heavy] >= located_share - 1e-9) {
      records$status[i] <- "located"
      records$lon[i] <- r$lon[heavy]; records$lat[i] <- r$lat[heavy]
    } else {
      records$status[i] <- "narrowed"
      cells <- rbind(cells, r[, c("record_id", "cell_id", "lon", "lat", "weight")])
    }
  }
  list(records = records, cells = cells)
}

#' lon/lat of the sites that define the reference set: located records, minus
#' flagged ones if the modeller chooses to exclude them until reviewed.
reference_xy <- function(states, flagged_ids, exclude_flagged = TRUE) {
  r <- states$records
  keep <- r$status == "located"
  if (exclude_flagged) keep <- keep & !(r$record_id %in% flagged_ids)
  r[keep, c("lon", "lat"), drop = FALSE]
}

#' Admin names in records that do not match any polygon (reported to the user,
#' never silently dropped).
unmatched_names <- function(records, admin) {
  nm <- unique(records$admin_name[!is.na(records$admin_name)])
  setdiff(nm, admin$admin_name)
}
