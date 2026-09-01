const DefaultClientNameBytes* = 48

proc defaultJackClientName*(pluginName: string): string =
  ## Produce a deterministic conservative ASCII JACK client name before the
  ## concrete JACK library's limit is available. The backend still validates
  ## the actual limit and reports any incompatibility.
  var pendingSeparator = false
  for character in pluginName:
    let accepted = character in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.'}
    if accepted:
      if pendingSeparator and result.len > 0 and result.len < DefaultClientNameBytes:
        result.add('-')
      pendingSeparator = false
      if result.len < DefaultClientNameBytes:
        result.add(character)
    else:
      pendingSeparator = result.len > 0
    if result.len >= DefaultClientNameBytes:
      break
  while result.len > 0 and result[^1] in {'-', '.'}:
    result.setLen(result.len - 1)
  if result.len == 0:
    result = "pluginhost"
