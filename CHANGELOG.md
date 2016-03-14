## RECENT CHANGES

14 Mar 2016: v0.9.4 Released
- Merged function codebase with osync and obackup projects
- Minor fixes

15 Jun 2013 - 14 Mar 2016: v0.1-v0.9.1
- Added destroy XX snapshots command
- Added support for zfsonlinux 0.6.4 zpool output being different
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
