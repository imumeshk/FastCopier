# Changelog

## [1.1.0] - 2026-11-20

### Added
- Transfer completion summary with succeeded, skipped, and failed item counts.
- Logs for directory traversal and transfer level failures.
- Preflight protection against copying a staged directory into itself.
- Transfer preflight with size, free-space, and top-level conflict estimates.
- Background directory loading with virtualized grid rows.
- Best-effort file timestamp and attribute preservation, plus directory timestamp preservation.
- Documentation of transfer behavior and known metadata and space-check limitations.

### Changed
- File copies now write to a temporary file before committing the destination.
- Existing destination files are preserved until the replacement copy is ready.
- Move staging now retains source items that still exist after the operation.
- Keep Both selects a name that is unused by either a file or directory.
- Overwrite prompt choices are stored on the prompt window to ensure the selected action is returned.
- Inaccessible paths and reparse-point directories are reported or skipped during recursive size and transfer scans.
- The window stays open until an active transfer has stopped.
- Pause now takes effect between files during same-volume moves and directory traversal.
- Transfer log filenames include a unique suffix to avoid replacing an earlier run's log.

### Fixed
- The background directory loader now compiles independently of the transfer helper types, so it is available when the script is run in a PowerShell session that already has older helper types loaded.
- Cross-volume moves no longer delete the source after an unsuccessful copy.
- Cancelled or failed copies remove incomplete temporary output.
- Size calculation warnings and directory-processing errors are recorded in the transfer log.
- Transfer logs are included in the final status summary when size estimation encounters inaccessible paths.
