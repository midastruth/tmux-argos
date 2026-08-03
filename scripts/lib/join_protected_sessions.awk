BEGIN {
  FS = "\t"
}
$0 == marker {
  reading_daemon = 1
  next
}
!reading_daemon {
  split($0, picker, "\t")
  session = picker[3]
  session_id = picker[11]
  if (!(session_id in matched)) {
    matched[session_id] = 1
    ordered[++count] = session_id
    names[session_id] = session
  }
  if (picker[10] == "working" || picker[10] == "blocked") {
    protected[session_id] = 1
  }
  next
}
reading_daemon && $0 != "" {
  field_count = split($0, daemon, "\037")
  if (field_count != 5 || daemon[2] !~ /^\$[0-9]+$/ || daemon[4] !~ /^(idle|done|working|blocked)$/ || daemon[5] !~ /^[0-9]+$/) {
    invalid_daemon_row = 1
    next
  }
  if (daemon[4] == "working" || daemon[4] == "blocked") {
    protected[daemon[2]] = 1
  }
}
END {
  if (invalid_daemon_row) {
    exit 1
  }
  for (order_index = 1; order_index <= count; order_index++) {
    session_id = ordered[order_index]
    session = names[session_id]
    is_protected = (session_id in protected) ? 1 : 0
    print session "\t" session_id "\t" is_protected
  }
}
