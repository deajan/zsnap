zsnap
=====

## About

Znsap script handles ZFS on linux snapshot functionnality, creates and handles snapshots in Samba VFS friendly format (Windows previous versions support).

## Installation

You can download the latest stable version of znsap directly on authors website or grab the latest working copy on git.

    $ git://github.com/deajan/zsnap.git
    $ chmod +x zsnap.sh
    
Once you have a copy of Zsnap, edit the configuration file to match your needs and you're ready to run.

## Usage

    $ ./zsnap.sh your_file.conf status
    $ ./zsnap.sh your_file.conf create

You may run multiple instances of zsnap by creating mutliple configuration files, one per dataset. You can easily add zsnap as cron task which will take snapshots at a given time.
The number of kept snapshots is handled by zsnap, but you may also control it's behaviour manually by using the following commands:

    $ ./zsnap.sh dataset.conf destroyoldest
    $ ./zsnap.sh other_dataset.conf destroyall

Zsnap will mount every snapshot in Samba's VFS object shadow_copy friendly format. Keep in mind that samba's VFS object only works if you share the root of your ZFS dataset or subdataset.

## Author

Orsiris "Ozy" de Jong
ozy@badministrateur.com
