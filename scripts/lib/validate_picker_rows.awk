BEGIN {
  FS = "\t"
}
NF != 13 || $1 !~ /^[0-9]+$/ || $2 !~ /^(session|pane|history|history-error)$/ || $3 == "" || $13 == "" {
  invalid_row = 1
  next
}
$2 == "session" {
  if ($10 !~ /^(idle|done|working|blocked)?$/ || $11 !~ /^\$[0-9]+$/ || $12 != "") {
    invalid_row = 1
    next
  }
  print
}
END {
  if (invalid_row) {
    exit 1
  }
}
