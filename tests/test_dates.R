# Run from repo root: Rscript tests/test_dates.R
source("R/dates.R")
eq <- function(got, want, what) if (!identical(got, want)) stop(sprintf("%s: got %s, want %s", what, deparse(got), deparse(want)), call. = FALSE)

p <- parse_partial_date(c("2019-04-17", "2019-04", "2019", "", NA, "garbage", "2019-13", " 2020-02 "))
eq(p$year,  c(2019L, 2019L, 2019L, NA, NA, NA, 2019L, 2020L), "years")
eq(p$month, c(4L, 4L, NA, NA, NA, NA, NA, 2L), "months")

eq(date_span_label("2018-03-04"), "Mar 2018", "single day")
eq(date_span_label(c("2018-03-04", "2021-11-30")), "Mar 2018 to Nov 2021", "span")
eq(date_span_label(c("2021-11-30", "2018-03-04")), "Mar 2018 to Nov 2021", "order independent")
eq(date_span_label(c("2018-03-04", "2018-03-28")), "Mar 2018", "same month collapses")
eq(date_span_label(c("2019", "2021-11")), "2019 to Nov 2021", "year-only start")
eq(date_span_label(c("2019", "2019-06")), "2019", "month inside a year-only record")
eq(date_span_label(c("2019-05", NA)), "May 2019 (+1 undated)", "undated counted")
eq(date_span_label(c(NA, "")), "undated", "all undated")
eq(date_span_label(character(0)), "", "no records")
cat("All date tests passed\n")
