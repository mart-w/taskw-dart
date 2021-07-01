void validateTaskDescription(String description) {
  if (description.substring(description.length - 1) == r'\') {
    throw FormatException(
      'Trailing backslashes may corrupt your Taskserver account.',
      description,
      description.length - 1,
    );
  } else if (description.contains('\n')) {
    throw FormatException(
      'Taskwarrior documentation on JSON format indicates your task '
      'description should not contain newline characters.',
      description,
      description.indexOf('\n'),
    );
  }
}
