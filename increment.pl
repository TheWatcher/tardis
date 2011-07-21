#!/usr/bin/perl -wT

## @file
# Server-side script to increment backup snapshots. This script should
# be invoked before syncing a new snapshot in order to increment the
# backups present on the server. This script will attempt to determine
# whether there is enough space in the backup image for the next backup,
# and if there is not it will remove snapshots, oldest first, until it
# frees enough space, or it hits the minimum snapshot count. Any errors
# encountered during the cleanup and increment process will result in an
# ERROR: message along with a description of the error. If this reports
# an error, it should be assumed that the backup can not be completed
# successfully, and the image should be unmounted without further changes.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 2.5
# @date    12 December 2010
# @copy    2010, Chris Page &lt;chris@starforge.co.uk&gt;

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
use strict;
use FindBin;             # Work out where we are
my $path;
BEGIN {
    $ENV{"PATH"} = ""; # Force no path.

    delete @ENV{qw(IFS CDPATH ENV BASH_ENV)}; # Clean up ENV

    # $FindBin::Bin is tainted by default, so we need to fix that
    if ($FindBin::Bin =~ /(.*)/) {
        $path = $1;
    }
}
use lib "$path/modules"; # Add the script path for module loading

# Custom modules to handle configuration settings and backup operations
use BackupSupport qw(path_join is_number humanise humanise_minutes dehumanise fallover df);
use ConfigMicro;

#$SIG{__WARN__} = sub
#{
#    my @loc = caller(1);
#    CORE::die "Warning generated at line $loc[2] in $loc[1]:\n", @_, "\n";
#};


## @fn $ sort_invnumeric()
# sort() comparator function for backup directory names. This extracts the numeric
# parts of the backup snapshot in $a and $b and compares the numbers (ensuring
# inverse numeric ordering, rather than the alphanumeric sort would use otherwise)
#
# @return 1 if $a should go before $b, 0 if they are the same, -1 if $a should
#         go after $b
sub sort_invnumeric {
    my ($an) = $a =~ /backup\.(\d+)$/;
    my ($bn) = $b =~ /backup\.(\d+)$/;

    $an = 0 if(!$an);
    $bn = 0 if(!$bn);
    return(-1 * ($an <=> $bn));
}


## @fn $ backup_clearspace($mountpoint, $reqbytes, $reqinodes, $metafile, $config)
# Attempt to ensure there is enough space in the backup directory for the
# next backup. This will determine whether the free space avilable in the
# backup directory is sufficient to contain the required data. If it is
# not, it will delete snapshots in reverse chronological order (oldest first)
# until it has either freed up enough space, or it can not delete any more
# snapshots.
#
# @param mountpoint The mountpoint corresponding to the backup directory.
# @param reqbytes   The amount of space required for the next backup, in bytes.
# @param reqinodes  The number of inodes needed for the next backup.
# @param metafile   The backup metadata file.
# @param config     A reference to the global configuration hash.
# @return true if there is enough space for the next backup, false if there
#         is not enough space available even after cleanup.
sub backup_clearspace {
    my $mountpoint = shift;
    my $reqbytes   = shift;
    my $reqinodes  = shift;
    my $metafile   = shift;
    my $config     = shift;

    # Begin by working out how much space we actually have available
    my ($size, $used, $free, $inodes, $freeinodes) = df($mountpoint, $config);

    # Add buffers
    $reqbytes  += dehumanise($config -> {"server"} -> {"bytebuffer"});
    $reqinodes += dehumanise($config -> {"server"} -> {"inodebuffer"});

    # Can the required size, plus buffer space, ever actually fit into the drive?
    # If the requested size is larger than the drive, or the drive limits inodes
    # and there aren't enough, give up right now...
    if($reqbytes >= $size || ($inodes && $reqinodes >= $inodes)) {
        print "ERROR: Requested backup could never fit into the backup image. Enlarge the image and try again.";
        return 0;
    }

    # Calculate space needed to duplicate backup.0 if needed
    if($inodes) {
        my $cmd = "$config->{paths}->{find} $mountpoint/backup.0 -printf \"%i\\n\" | $config->{paths}->{sort} -u | $config->{paths}->{wc} -l";
        my ($cmdunt) = $cmd =~ /^(.*)$/;

        my $backupinodes = `$cmdunt`;
        $reqinodes += $backupinodes if($backupinodes);
    }

    # Does the required size fit in the free space?
    if($reqbytes <= $free && ($freeinodes == -1 || ($reqinodes < $freeinodes))) {
        print "Requested backup size plus buffer (",humanise($reqbytes),") will fit into available backup space (",humanise($free),").\n";
        return 1;
    } else {
        print "Requested backup does not fit into available space:\n";
        printf("%d bytes must be freed (%d are needed, %d available)\n",
               $reqbytes - $free, $reqbytes, $free) if($free < $reqbytes);
        printf("%d inodes must be freed (%d are needed, %d available)\n",
               $reqinodes - $freeinodes, $reqinodes, $freeinodes) if($freeinodes > -1 && $freeinodes < $reqinodes);
    }

    # Now get a reverse-sorted list of directories to start deleting from
    my @indirs = glob("$mountpoint/backup.*");
    my @dirs = sort sort_invnumeric @indirs if(scalar(@indirs));

    # Remove the forcibly retained directories from the end of the list
    if($config -> {"server"} -> {"forcesnaps"} > 0) {
        # Are there actually enough backups in the list?
        fallover("ERROR: unable to safely delete any snapshots to free up space (not enough snapshots present).\n", 74)
            if(scalar(@dirs) <= $config -> {"server"} -> {"forcesnaps"});

        # Remove the directories that must be retained
        splice(@dirs, -1 * $config -> {"server"} -> {"forcesnaps"});
    }

    # Okay, delete directories until we get enough space or have gone through them all...
    my $pos = 0;
    my $sfree  = $free;
    my $sifree = $freeinodes;
    while((($free < $reqbytes) || ($freeinodes > -1 && $freeinodes < $reqinodes)) && ($pos < scalar(@dirs))) {
        my $deaddir = $dirs[$pos++];

        print "Removing $deaddir\n";

        # Check that the directory can be deleted
        my ($dirid) = $deaddir =~ /\.(\d+)$/;
        fallover("ERROR: Unable to determine directory id from '$deaddir'. Giving up.\n", 74)
            if(!$dirid);

        # Prevent directories from being deleted if the id is less than the preserve level
        fallover("ERROR: Unable to remove forcibly preserved directory '$deaddir'.\n", 74)
            if($config -> {"server"} -> {"forcesnaps"} && $dirid < $config -> {"server"} -> {"forcesnaps"});

        my $cmd = "$config->{paths}->{rm} -rf $deaddir";
        my ($cmdunt) = $cmd =~ /^(.*)$/;

        # This shouldn't output anything, but hey...
        print `$cmdunt`;

        # We only need the backup part of the name for the metafile operation
        my ($backup) = $deaddir =~ /(backup.\d+)/;

        fallover("ERROR: Unable to obtain backup id from '$deaddir'. This Should Not Happen!\n")
            if(!$backup);

        # Remove the appropriate entry from the metafile
        delete $metafile -> {"snapshots"} -> {$backup};

        # Update the stats to see whether we have enough free space yet
        ($size, $used, $free, $inodes, $freeinodes) = df($mountpoint, $config);
    }

    # Have we freed enough for the backup?
    if($free >= $reqbytes && ($freeinodes == -1 || $freeinodes > $reqinodes)) {
        print "Cleanup has released ",humanise($free - $sfree)," of the oldest backups to make space for new data.\n";
        return 1;
    }

    # Seems not!
    print "ERROR: Unable to release enough space for new backup data.\n";
    return 0;
}


## @fn $ backup_increment($mountpoint, $metafile, $config)
# Increment the snapshot directories in the specified backup. This will move
# all snapshots in the backup directory along by one slot, updating their
# metadata at the same time. Once all but backup.0 have been moved, backup.0
# is copied to backup.1 with cpio to create hardlinked copies of files.
#
# @param mountpoint  The mountpoint corresponding to the backup directory.
# @param metafile    The backup metadata file.
# @param config      A reference to the global configuration hash.
# @return true if the backups have been incremented successfully, false if
#         a problem occurred.
sub backup_increment {
    my $mountpoint = shift;
    my $metafile   = shift;
    my $config     = shift;

    # get the directories in the backup
    my @sdirs = glob("$mountpoint/backup.*");
    my @dirs = sort sort_invnumeric @sdirs if(scalar(@sdirs));

    # work out what the last snapshot number is if we have more than 1 backup directory (backup.0)
    if(scalar(@dirs) > 1) {
        my ($count) = $dirs[0] =~ /backup\.(\d+)$/;

        # Count MUST be 1 or greater, it must NEVER be 0, or all hell breaks loose
        if($count >= 1) {
            print "Incrementing snapshots... ";
            # Move the snaps along by one.
            for(my $i = $count; $i > 0; --$i) {
                my $j = $i + 1;

                # Work out the source and destination directory names
                my $src = path_join($mountpoint, "backup.$i");
                my $dst = path_join($mountpoint, "backup.$j");

                # If the source exists, move it to the destination
                if(-d $src) {
                    print `$config->{paths}->{mv} $src $dst 2>&1`;

                    # Remember to update the metadata, too
                    $metafile -> {"snapshots"} -> {"backup.$j"} = $metafile -> {"snapshots"} -> {"backup.$i"};
                }
            }
            print "moved $count directories. Complete\n";
        } else {
            print "ERROR: last backup directory appears to be 0. Something is very broken!\n";
            return 0;
        }
    }

    # If the base snapshot exist, use cpio to create the next one. This
    # has the effect of doing copy-on-write when used with rsync as
    # hard links in .0 are unlinked before update/delete, but they
    # will remain in .1
    my $snap = path_join($mountpoint, "backup.0");
    if(-d $snap) {
        my $copy = path_join($mountpoint, "backup.1");
        print "Coping $snap to $copy\n";

        # Do the cpio, reword the block return if needed (which we hopt it will be
        my $cpres = `cd $snap && $config->{paths}->{find} . -print | $config->{paths}->{cpio} -dplm $copy 2>&1`;
        $cpres =~ s/0 blocks/cpio reports all files created as links, 0 blocks written (Note: this is good)./;
        print $cpres;

        $metafile -> {"snapshots"} -> {"backup.1"} = $metafile -> {"snapshots"} -> {"backup.0"};
    }

    return 1;
}


## @fn void display_stats($mountpoint, $required, $metafile, $config)
# Print out statistics about the backup image. This will attempt to determine
# how much space is left for backups, or how long backups are being retained
# for.
#
# @param mountpoint The mountpoint corresponding to the backup directory.
# @param required   The amount of space required for the next backup,
#                   in bytes.
# @param metafile   The backup metadata file.
# @param config     A reference to the global configuration hash.
sub display_stats {
    my $mountpoint = shift;
    my $required   = shift;
    my $metafile   = shift;
    my $config     = shift;

    # Begin by working out how much space we  have available
    my ($size, $used, $free) = df($mountpoint, $config);

    # get the list of backup directories...
    my @bdirs = glob("$mountpoint/backup.*");

    printf("Image contains %s worth of backups, occupying %s space.\n", humanise_minutes(scalar(@bdirs) * $config -> {"client"} -> {"backupfreq"}), humanise($used));

    if($required && $free) {
        if($free > $required) {
            printf("At current rate, there is space for %s worth of additional backups.\n", humanise_minutes(int($free / $required) * $config -> {"client"} -> {"backupfreq"}));
        }
    } elsif($free) {
        print "Unable to estimate how many more backups can be stored at this time.\n";
    }
}


# First make sure that this script is being run as root (running as non-root
# would royally mess up permissions retention)
fallover("ERROR: This script must be run as root to operate successfully.\n")
    if($> != 0);

# We need three arguments: the config, the id of the directory to increment,
# and the space needed
if(scalar(@ARGV) == 4) {

    # Ensure the config file is valid, and exists
    my ($configfile) = $ARGV[0] =~ /^(\w+)$/;
    faillover("ERROR: The specified config file name is not valid, or does not exist")
        if(!$configfile || !-f "$path/config/$configfile.cfg");

    # Bomb if the config file is not at most 600
    my $mode = (stat("$path/config/$configfile.cfg"))[2];
    fallover("ERROR: $configfile.cfg must have at most mode 600.\nFix the permissions on $configfile.cfg and try again.\n", 77)
        if($mode & 07177);

    # Load the configuration
    my $config = ConfigMicro -> new("$path/config/$configfile.cfg")
        or fallover("ERROR: Unable to load configuration. Error was: $ConfigMicro::errstr\n", 74);


    # check that the second argument - the directory id - is actually numeric
    if($ARGV[1] =~ /^\d+$/) {
        # Check that the third argument - the space required - is numeric
        if(is_number($ARGV[2])) {

            # Check that the fourth argument - the inodes required - is numeric
            if(is_number($ARGV[3])) {
                # Check that the directory exists, we don't want to do anything if it doesn't
                if($config -> {"directory.$ARGV[1]"}) {

                    # Work out what the mountpoint for the directory is...
                    my $mountpoint = path_join($config -> {"server"} -> {"base"}, $config -> {"directory.$ARGV[1]"} -> {"remotedir"});

                    # Okay, make sure that the directory exists
                    if(-d $mountpoint) {
                        # Now we need to grab the metafile
                        my $metafile = ConfigMicro -> new(path_join($mountpoint, ".tardis_meta"));
                        if($metafile) {

                            # We have the metafile, mountpoint, and other gubbins. Time to make sure we have space...
                            if(backup_clearspace($mountpoint, dehumanise($ARGV[2]), dehumanise($ARGV[3]), $metafile, $config)) {

                                # now move all the backups down one
                                backup_increment($mountpoint, $metafile, $config);

                                display_stats($mountpoint, dehumanise($ARGV[2]), $metafile, $config);
                            }

                            # Write back the metafile to record the changes made. This needs to be done even
                            # if the cleanup fails, as we may have deleted directories...
                            $metafile -> write(undef, 1)
                                or fallover("ERROR: Unable to write backup metafile. Error was: ".$ConfigMicro::errstr."\n");

                            print "Increment completed successfully.\n";
                        } else {
                            fallover("ERROR: Unable to open backup metafile. Error was: ".$ConfigMicro::errstr."\n");
                        }
                    } else { # if(-d $mountpoint) {
                        fallover("ERROR: backup directory does not exist. This should not happen.\n", 74);
                    }
                } else { # if($config -> {"directory.$ARGV[1]"}) {
                    fallover("ERROR: The specified directory id is not valid.\n");
                }
            } else { # if(is_number($ARGV[3])) {
                fallover("ERROR: required inodes must be numeric.\n", 64);
            }
        } else { # if(is_number($ARGV[2])) {
            fallover("ERROR: required space must be numeric.\n", 64);
        }
    } else { # if($ARGV[1] =~ /^\d+$/) {
        fallover("ERROR: directory id must be numeric.\n", 64);
    }
} else { # if(scalar(@ARGV) == 3) {
    fallover("ERROR: Incorrect number of arguments.\nUsage: increment.pl <config> <directory id> <space required> <inodes required>\n", 64);
}
