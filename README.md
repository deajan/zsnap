zsnap
=====

## About

Znsap script handles ZFS on linux snapshot functionnality, creates and handles a defined number of snapshots in Samba VFS friendly format (Windows previous versions support).
It will send an alert mail if any snapshot related functionnality creates an error.

## Installation

You can download the latest stable version of znsap directly on authors website or grab the latest working copy on git.

    $ git://github.com/deajan/zsnap.git
    $ chmod +x zsnap.sh

Additionnaly, you may copy zsnap.sh to /usr/local/bin

    $ cp zsnap.sh /usr/local/bin
    
Once you have a copy of Zsnap, edit the configuration file to match your needs and you're ready to run.

## Usage

    $ zsnap.sh /path/to/your.conf status
    $ zsnap.sh /path/to/your.conf create

You may run multiple instances of zsnap by creating mutliple configuration files, one per dataset.
You can easily add zsnap as cron task which will take snapshots at a given time. Use parameter --silent to prevent writing to stdout for crontasks.

    $ ./zsnap.sh /path/to/your.conf create --silent

The number of kept snapshots is handled by zsnap, but you may also control it's behaviour manually by using the following commands:

    $ ./zsnap.sh /path/to/dataset.conf destroyoldest
    $ ./zsnap.sh /another/path/other_dataset.conf destroyall

You may increase output level of zsnap script by adding parameter --verbose to see what is actually going on

    $ ./zsnap.sh /my/conf/files/my.conf create --verbose

Zsnap will mount every snapshot in Samba's VFS object shadow_copy friendly format. Keep in mind that samba's VFS object only works if you share the root of your ZFS dataset or subdataset.


## Author

Orsiris "Ozy" de Jong
ozy@badministrateur.com
