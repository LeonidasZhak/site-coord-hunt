# Partial dates. Records may carry "YYYY-MM-DD", "YYYY-MM", "YYYY" or nothing.

#' Split partial dates into year and month (month is NA for year-only dates).
#' Anything that is not a recognisable partial date counts as undated; an
#' impossible month (e.g. "2019-13") falls back to year-only.
parse_partial_date <- function(x) {
  x <- trimws(as.character(x))
  year <- month <- rep(NA_integer_, length(x))
  ok <- !is.na(x) & grepl("^[0-9]{4}(-[0-9]{1,2}(-[0-9]{1,2})?)?$", x)
  parts <- strsplit(x[ok], "-", fixed = TRUE)
  year[ok]  <- as.integer(vapply(parts, `[`, "", 1))
  month[ok] <- suppressWarnings(as.integer(
    vapply(parts, function(p) if (length(p) >= 2) p[2] else NA_character_, "")))
  month[!is.na(month) & (month < 1 | month > 12)] <- NA_integer_
  data.frame(year = year, month = month)
}

#' One-line time span for a set of records, e.g. "Mar 2018 to Nov 2021".
#' A year-only endpoint is shown as a year; undated records are counted, not
#' guessed at.
date_span_label <- function(x) {
  if (length(x) == 0) return("")
  d <- parse_partial_date(x)
  n_undated <- sum(is.na(d$year))
  d <- d[!is.na(d$year), , drop = FALSE]
  if (nrow(d) == 0) return("undated")
  fmt <- function(y, m) if (is.na(m)) as.character(y) else paste(month.abb[m], y)
  # A year-only date could fall anywhere in its year: earliest it can start is
  # January, latest it can end is December.
  start <- d$year * 12 + ifelse(is.na(d$month), 0, d$month - 1)
  end   <- d$year * 12 + ifelse(is.na(d$month), 11, d$month - 1)
  i <- which.min(start); j <- which.max(end)
  a <- fmt(d$year[i], d$month[i]); b <- fmt(d$year[j], d$month[j])
  lab <- if (a == b) a else paste(a, "to", b)
  if (n_undated > 0) lab <- sprintf("%s (+%d undated)", lab, n_undated)
  lab
}
