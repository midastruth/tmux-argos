BEGIN {
  detected_count = split(detects, detected_commands, /[[:space:]]+/)
  for (command_index = 1; command_index <= detected_count; command_index++) {
    if (detected_commands[command_index] != "") {
      wanted[detected_commands[command_index]] = 1
    }
  }
}
NF >= 3 {
  process_id = $1
  parent_id = $2
  command = $3
  sub(/^.*\//, "", command)
  commands[process_id] = command
  children[parent_id] = children[parent_id] " " process_id
}
END {
  if (commands[root] in wanted) {
    print commands[root]
    exit 0
  }
  head = 1
  tail = 1
  queue[1] = root
  seen[root] = 1
  while (head <= tail) {
    current = queue[head++]
    child_count = split(children[current], child_ids, " ")
    for (child_index = 1; child_index <= child_count; child_index++) {
      child = child_ids[child_index]
      if (child == "" || seen[child] || child == current) {
        continue
      }
      seen[child] = 1
      if (commands[child] in wanted) {
        print commands[child]
        exit 0
      }
      queue[++tail] = child
    }
  }
  exit 1
}
