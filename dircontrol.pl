#!/usr/bin/perl -wT

## @file
# Server-side script for mount point directory control. This script contains the
# code needed to create, mount, and unmount backup directory images on the
# server. It should be called to mount a backup image before doing the
# backup increment and rsync operations, and then called to unmount the
# backup image once the backup operations are complete. Image file size
# and usage are reported on successful mount or unmount. Any error conditions
# encountered during execution will result in "ERROR: ..." printed to
# STDERR, and the caller should assume that the backup can not be used safely.
#
# @note This script *MUST* run as root (not even setuid - you need to use
#       sudo at least): it makes use of several features only available to
#       root. Notably, it needs to be able to mount an imagefile without
#       an entry in fstab, and more importantly it needs to be able to
#       unmount a loop device (which a normal user can't do, even if the
#       imagefile is in fstab).
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.6
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
use BackupSupport qw(path_join humanise dehumanise fallover df);
use ConfigMicro;

#$SIG{__WARN__} = sub
#{
#    my @loc = caller(1);
#    CORE::die "Warning generated at line $loc[2] in $loc[1]:\n", @_, "\n";
#};


## @fn void print_stats($imagefile, $mountpoint, $config)
# Print the disc usage stats for the backup image mounted on the specified
# mountpoint, and some information about the sparse imagefile.
#
# @param imagefile  The imagefile to show stats for.
# @param mountpoint The mountpoint to show the stats for.
# @param config     A reference to the system configuration hash.
sub print_stats {
    my $imagefile  = shift;
    my $mountpoint = shift;
    my $config     = shift;

    my $image_real   = `$config->{paths}->{du} -B 1 $imagefile`;
    my $image_appear = `$config->{paths}->{du} -b $imagefile`;

    # pull out numbers we want from the stats first
    my ($msize, $mused, $mfree, $inodes, $ifree) = df($mountpoint, $config);
    if(defined($msize) && defined($mused) && defined($mfree)) {
        printf("Backup usage: %s of %s (%d%%) used, %s (%d%%) free%s.\n",
               humanise($mused), humanise($msize), 100 * ($mused / $msize),
               humanise($mfree), 100 * ($mfree / $msize),
               $inodes ? sprintf(". %d of %d inodes used, %d free", $inodes - $ifree, $inodes, $ifree) : "");
    } else {
        print "Unable to determine backup statistics.\n";
    }

    # Now interpret and use the image information
    my ($realsize) = $image_real =~ /^(\d+)/;
    my ($appearsize) = $image_appear =~ /^(\d+)/;

    if(defined($realsize) && defined($appearsize)) {
        printf(" Image usage: %s apparent size, %s actual usage\n",
               humanise($appearsize),
               humanise($realsize));
    } else {
        print "Unable to determine image statistics.\n";
    }
}


## @fn $ check_mountpath($path)
# Determine whether the specified mountpoint path exists. If the directory
# does not exist, this attempts to create it.
#
# @param path     The path to the mountpoint.
# @param makepath optional argument to control whether the mountpoint should
#                 be created if it does not exist. Set to true to enable
#                 creation, false to exit if the directory does not exist.
#                 If not specified, this defaults to true.
# @return true if the mount point exists or has been created, false if it
#         does not and can not.
sub check_mountpoint {
    my $path     = shift;
    my $makepath = shift;

    # set up makepath so it is enabled by default
    $makepath = 1 if(!defined($makepath));

    # Does the directory exist? If so, we're good to go...
    return 1 if(-d $path);

    if($makepath) {
        # It doesn't exist, can we create it?
        mkdir($path)
            or warn "ERROR: Unable to create mount path '$path': $!\n";
    }

    # Let -d handle the check here...
    return -d $path;
}


## @fn $ check_imagefile($imagefile, $filesize, $fstype, $mkfsargs, $config)
# Determine whether the imagefile exists. If it does not, create it as a
# sparse image file and format it with the specified filesystem.
#
# @param imagefile  The name of the imagefile to check.
# @param filesize   The size of the (sparse) file to create. May end in K/M/G
#                   for KB, MB, or GB sizes.
# @param fstype     Filesystem type to use when formatting.
# @param mkfsargs   Arguments to pass to the mkfs command if the imagefile
#                   needs to be created and formatted.
# @param config     A reference to the system configuration hash.
# @return 1 if the imagefile exists, 2 if it was created (and needs additional
#         setup after mounting), 0 if any errors were encontered.
sub check_imagefile {
    my ($imagefile, $filesize, $fstype, $mkfsargs, $config) = @_;

    # Okay, does the file exist as a normal file? If so, life is easy...
    return 1 if(-f $imagefile);

    # Otherwise, does it exist in some form? If so, we have a problem
    if(-e $imagefile) {
        warn "ERROR: imagefile '$imagefile' blocked by existing entry.\n";
        return 0;
    }

    print "Backup image does not exist. Creating image, one moment please...\n";

    # Okay, it doesn't exist in any form, so we can create it...
    my $dd = `$config->{paths}->{dd} if=/dev/zero of=$imagefile bs=1 count=1 seek=$filesize 2>&1`;

    # Check that dd worked and the image is there
    if($dd !~ /^1 byte\s*\(1 B\) copied/m) {
        chomp($dd);
        warn "ERROR: imagefile $imagefile creation failed. dd returned:\n'$dd'\n";
        return 0;
    }

    if(!-f $imagefile) {
        warn "ERROR: imagefile $imagefile is missing after create.\n";
        return 0;
    }

    print "Backup image created, formatting to $fstype.\n";

    # Okay, the imagefile is there, now we need to format it.
    # First we need to get the image connected to a loop device
    my $losetup = `$config->{paths}->{losetup} -f --show $imagefile 2>&1`;

    # check that losetup could be used
    if($losetup =~ /no permission to look at/) {
        warn "ERROR: unable to create imagefile: $losetup";
        return 0;
    }

    # Check that we have a useful number from losetup
    my ($loop) = $losetup =~ m{^(/dev/loop/?\d+)$}m;
    if(!$loop) {
        warn "ERROR: losetup did not provide a valid loop device (result was: $losetup). Unable to format image file.\n";
        return 0;
    }

    # We have a loop device to work with, so format it
    my $output = `$config->{paths}->{mkfs} -t $fstype $mkfsargs $loop 2>&1`;
    my $status = ($? & 0xFF00) >> 8; # record the exit status

    # We don't need the loop device now
    `$config->{paths}->{losetup} -d $loop 2>&1`;

    # Is the result of the mkfs zero? Note that $? is the full 16 bit
    # result from wait*(), with the actual result in the upper byte.
    if($status != 0) {
        warn "ERROR: mkfs call reported an error on exit. Output was: $output";
        return 0;
    }

    print "Backup image formatted successfully and is ready for use.\n";

    # get here and we created and formatted okay!
    return 2;
}


## @fn $ mount_imagefile($imagefile, $mountpoint, $filesystem, $mountargs, $size, $user, $group, $config)
# Try to mount the specified image file and verify its size. This will check
# whether the image is already mounted before trying to mount it. Once the
# image is mounted, the size is checked against the setting stored in the
# drive. If the size setting is not found, it is created.
#
# @param imagefile  The name of the imagefile to mount.
# @param mountpoint The mountpoint to mount the imagefile on.
# @param filesystem The filesystem used in the imagefile.
# @param mountargs  The arguments to append to the mount options
# @param size       The size of the backup imagefile.
# @param user       If this and group are specified, the newly-mounted mountpoint
#                   has its owner details updated.
# @param group      If this and group are specified, the newly-mounted mountpoint
#                   has its owner details updated.
# @param config     A reference to the system configuration hash.
# @return 1 if the image has been mounted and the size matches the size recorded
#         in the imagefile. 0 if the image can not be mounted. Any other value
#         indicates that the image has been mounted, but the size recorded in the
#         imagefile does not match the specified size. The value returned is the
#         size recorded in the imagefile.
sub mount_imagefile {
    my ($imagefile, $mountpoint, $filesystem, $mountargs, $size, $user, $group, $config) = @_;

    # First ask mount whether the mountpoint is already mounted.
    my $mount = `$config->{paths}->{mount} -l | $config->{paths}->{grep} $mountpoint 2>&1`;

    # If the mountpoint is mounted at all, $mount will contain something
    if($mount) {
        print "Backup image appears to be mounted already, verifying filesystem.\n";

        # Okay, it's mounted, does it have a matching filetype?
        my ($fstest) = $mount =~ /type (\w+)/;

        # If we can't identify the type, give up.
        if(!$fstest) {
            warn "ERROR: unable to identify type of filesystem mounted on $mountpoint.\n";
            return 0;
        }

        # We have a type, does it match?
        if($fstest ne $filesystem) {
            warn "ERROR: type of filesystem mounted on $mountpoint, exected $fstest.\n";
            return 0
        }

        # Okay, it's mounted and matches. For now, we can leave off checking...

    # Mountpoint is not mounted. Try to mount it...
    } else {
        # Work out what the options should be...
        my $args = "-o loop";
        $args .= ",$mountargs" if($mountargs);

        # Okay, here we go...
        $mount = `$config->{paths}->{mount} -t $filesystem $imagefile $mountpoint $args 2>&1`;

        # Did it work?
        if((($? & 0xFF00) >> 8) != 0) {
            warn "ERROR: Unable to mount $imagefile on $mountpoint.\nERROR: mount returned: $mount\n";
            return 0;
        }
    }

    # Get here and the imagefile is mounted on $mountpoint. Now we need to check the metafile
    my $metafile = path_join($mountpoint, ".tardis_meta");
    my $metadata;

    # If the file exists, load it so we can check the size
    if(-f $metafile) {
        $metadata = ConfigMicro -> new($metafile);

        # Did we actually get anything?
        if(!$metadata) {
            warn "ERROR: $imagefile is mounted, but .tardis_meta can not be opened. This Should Not Happen!\nError was: ".$ConfigMicro::errstr;
            return 0;
        }

    # The metafile doesn't exist, probably this is a new image. Create it, set the size,
    # and write the metafile out.
    } else {
        print "Backup image appears to be new, creating metafile.\n";
        $metadata = ConfigMicro -> new();

        $metadata -> set_value("image", "size", $size);
        if(!$metadata -> write($metafile)) {
            warn "ERROR: $imagefile is mounted, but .tardis_meta can not be written. Error was: ".$ConfigMicro::errstr."\n";
            return 0;
        }
    }

    # Get here an we have metadata. Before we compare the sizes, update the user and group if specified
    `$config->{paths}->{chown} -R $user:$group $mountpoint` if($user && $group);

    # Now we can do the size compare..
    return ($size == $metadata -> {"image"} -> {"size"}) ? 1 : $metadata -> {"image"} -> {"size"};
}


## @fn $ mount($id, $config)
# Attempt to mount the image corresponding to the specified directory id.
#
# @param id     The id of the directory to mount.
# @param config A reference to the system configuration hash.
# @return true if the imagefile has been mounted, false if it has not.
sub mount {
    my $id     = shift;
    my $config = shift;

    # Only actually do anything if the id corresponds to a valid directory
    if($config -> {"directory.$id"}) {

        # Precalculate some things to make the later calls less-brainbendy
        my $mountpoint = path_join($config -> {"server"} -> {"base"}, $config -> {"directory.$id"} -> {"remotedir"});
        my $imagefile  = $mountpoint.".timg";
        my $filesize   = dehumanise($config -> {"directory.$id"} -> {"maxsize"});


        if(check_mountpoint($mountpoint)) {
            # We need to record the result from mount, to see whether we need to
            # provide extra information to mount_imagefile
            if(my $imagestate = check_imagefile($imagefile,
                                                $filesize,
                                                $config -> {"server"} -> {"fstype"},
                                                $config -> {"server"} -> {"fsopts"},
                                                $config)) {
                # okay, now we can actually mount the image
                if(my $size = mount_imagefile($imagefile,
                                              $mountpoint,
                                              $config -> {"server"} -> {"fstype"},
                                              $config -> {"server"} -> {"mountargs"},
                                              $filesize,
                                              ($imagestate == 2) ? $config -> {"server"} -> {"user"} : undef,
                                              ($imagestate == 2) ? $config -> {"server"} -> {"group"} : undef,
                                              $config)) {
                    print "Backup image mounted successfully.\n";

                    # If the size is not 1, the image and configuration do not agree on size
                    print "WARNING: backup image reports size of ",humanise($size),", expected ",humanise($filesize),". Image size will be used, use resize.pl to fix this!\n"
                        if($size > 1);

                    print_stats($imagefile, $mountpoint, $config);
                    return 1;
                }
            }
        }
    } else {
        warn "ERROR: Invalid directory id specified.\n";
    }

    # Get here and there was a big problem.
    fallover("ERROR: unable to ensure safe mount. Aborted for safety.\n", 32);
}


## @fn $ unmount($id, $config)
# Attempt to unmount the directory corresponding to the specified directory id.
#
# @param id     The id of the directory to unmount.
# @param config A reference to the system configuration hash.
# @return true if the imagefile has been unmounted, false if it has not.
sub unmount {
    my $id     = shift;
    my $config = shift;

    # Only actually do anything if the id corresponds to a valid directory
    if($config -> {"directory.$id"}) {

        # Precalculate some things to make the later calls less-brainbendy
        my $mountpoint = path_join($config -> {"server"} -> {"base"}, $config -> {"directory.$id"} -> {"remotedir"});
        my $imagefile  = $mountpoint.".timg";

        # Don't bother doing anything if the mountpoint isn't there
        if(check_mountpoint($mountpoint, 0)) {

            # Is the mountpoint actually mounted?
            my $mount = `$config->{paths}->{mount} -l | $config->{paths}->{grep} $mountpoint 2>&1`;

            if($mount) {
                print_stats($imagefile, $mountpoint, $config);

                # image is mounted, attempt to unmount it...
                $mount = `$config->{paths}->{umount} $mountpoint`;

                # Did the unmount work? If so, umount will have exited with status 0.
                if(($? & 0xFF00) >> 8 == 0) {
                    print "Backup image unmounted successfully.\n";
                    return 1;
                }

                warn "WARNING: Unable to unmount backup image. umount returned: $mount";
            } else {
                warn "ERROR: $mountpoint isn't mounted?! This should not happen!\n";
            }
        }
    } else {
        warn "ERROR: Invalid directory id specified.\n";
    }

    return 0;
}


# First make sure that this script is being run as root
fallover("ERROR: This script must be run as root to operate successfully.\n")
    if($> != 0);

# Make sure that we have enough arguments. We need three: the config name, the id
# of the directory to work on, and the operation to perform ('mount' or 'umount')
if(scalar(@ARGV) == 3) {

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

        # determine which operation is required
        if($ARGV[2] eq "mount") {
            mount($ARGV[1], $config);

        } elsif($ARGV[2] eq "umount") {
            unmount($ARGV[1], $config);
        } else {
            fallover("ERROR: bad operation selected.\n", 64);
        }
    } else { # if($ARGV[1] =~ /^\d+$/) {
        fallover("ERROR: directory id must be numeric.\n", 64);
    }
} else { # if(scalar(@ARGV) == 3) {
    fallover("ERROR: Incorrect number of arguments.\nUsage: dircontrol.pl <config> <directory id> <mount|umount>\n", 64);
}
