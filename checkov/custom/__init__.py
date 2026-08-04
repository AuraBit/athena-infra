# __init__.py -- required for Checkov's external-checks-dir loader (Plan
# 02-05, Task 1). Empirically confirmed against this repo's pinned checkov
# 3.3.9: without this file, the loader logs "No __init__.py found ...
# Cannot load any check here" and silently skips every check in this
# directory, including athena_required_tags.py -- the custom check would
# never actually run, despite .checkov.yaml's external-checks-dir wiring
# looking correct. This file's only job is to make this directory an
# importable Python package.
