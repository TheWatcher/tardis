Quick'n'dirty install instructions
==================================

tardis is a remote, incremental backup system. Each backup created by tardis
appears to be a complete snapshot of the backed-up data at the backup time,
whereas in reality each backup only occupies the space required for the
directory tree and files updated since the last backup.

Requirements
------------

On the client machine (the machine containing resources to be backed up), you
will need:

- Perl 5 (tested with 5.8 and 5.12)
- Perl DBI
- mysql and mysqldump if you intend to make mysql backups
- rsync
- ssh

You should also have some kind of MTA on the client, with sendmail accessible,
to email logs to an administrator.

The backup server needs:

- Perl 5
- Perl DBI
- rsync
- sudo
- A sshd running
- Standard core tools (rm, cpio, mount)
- More than one available filesystem (I use reiserfs for the physical drives,
  and XFS for images, but you can theoretically use any combination as long
  as the images do not use the same filesystem as the physical drives. Using
  same for both can lead to Interesting Problems if fsck is used)

Doing the install
-----------------

- On the backup server (henceforth "server"):
    - set up a partition large enough to store your backup images, with some
      wiggle room.
    - mount it, and note down the mount point. For these instructions, I
      assume you called it `/backup`
    - create a user that will do the backups, and a matching group. I will
      assume you used `thedoctor:thedoctor`
    - add the following to the server sudoers, modify the user and `/backup`
      path if needed.

        thedoctor ALL= NOPASSWD: /usr/bin/rsync,/backup/tardis/dircontrol.pl,/backup/tardis/increment.pl,/backup/tardis/marksnapshot.pl

- On the client machine, where you probably want to do all this as root:
    - generate a ssh key, copy the public key to the server, and add it
      to the authorized_keys for the backup user on the server (ie:
      set up public key auth for the client user to connect to the
      backup user on the server).
    - place a copy of the tardis directory somewhere, probably in
      `/root/tardis`
    - open `/root/tardis/config/example.cfg` and modify the values to
      match your environment and backup requirements.
    - save the configuration as <client>.cfg, replacing <client> with
      the hostname of your machine (if your machine is foo.bar.com use
      foo.cfg)
    - create the local log and temporary work directory, eg: `mkdir -p /root/backup/logs`
    - copy the entire `/root/tardis` directory to `/backup/tardis` on the server.

- On the server:
    - check that all the paths in `/backup/tardis/configs/<client>.cfg`
      are correct for your server.

Now, before you can make the system automated, you should run the
following on the client to create the initial backup, as it can take
a long time if you have a lot of data to begin with:

    /root/tardis/tardis.pl <client>.cfg

replacing <client> with the hostname as above. If that completes
without errors on the terminal or the email sent to the admin, you
can add a cron job that will invoke the tardis.pl script with the
frequency you desire. For example, hourly backups:

    0 * * * * /root/tardis/tardis.pl <client>

replacing <client> with the hostname, eg:

    0 * * * * /root/tardis/tardis.pl foo

The backup script will retain as many backups on the server as it
has space for. Once the space is used up, older backups are removed
to make way for new.

Recovery
--------

Should you need to recover data, the proceedure is as follows:

- for databases dumps, look in the appropriate subdirectory in
  /backup on the server for the dump you need. Each dump should
  be a stand-alone snapshot of the database or databases at the
  time of the timestamp in the filename. They can be copied to
  the client machine and restored as normal.

- for directory backups, you will need to mount the appropriate
  image first, the easiest way to do this:
    - log into the server, become root
    - mount the image using (where <client> is the name of the
      client whose image you want to mount, and <dirid> is the id
      of the directory group to mount):

        /backup/tardis/dircontrol.pl <client> <dirid> mount

    - once mounted on the appropriate mountpoint, you will be
      able to access the backups inside the image. The latest
      backup is stored in backup.0 and older backups are stored
      in increasing backup.N directories. Each backup.N directory
      will appear to be a complete backup of all files at the
      time the backup was made.
    - once you have copied out the files and directories you need
      to recover, you should unmount the image using (where
      <client> and <dirid> match the values provided to the
      earlier mount call):

        /backup/tardis/dircontrol.pl <client> <dirid> umount

