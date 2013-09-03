## RECENT CHANGES

- Removed unnecessary warning in CountSnaps if there aren't any snaps
- Added leading ^ in grep arguments as disambigution in the highly unlikely case you have dataset names containing other dataset names
- Added warning if MAX_SPACE disk usage reached
- Added vfs object shadow_copy2 compatibility (actually same code, but no need to mount snapshots)
- Fixed batch unmount stopped on erroro
- Added --silent and --verbose parameters
- Fixed various minor glitches
- Added option to disable UTC time format use
- Improved handling of SendAlert function
- Fixed email sending options

15 Jun 2013

- Initial public release
