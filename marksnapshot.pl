#!/usr/bin/perl -wT

## @file
# Server-side script to mark the time at which the latest snapshot was
# completed. This updates the entry corresponding to backup.0 in the
# backup metadata to reflect the current time.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 2.3
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
use BackupSupport qw(path_join is_number humanise dehumanise fallover df);
use ConfigMicro;

$SIG{__WARN__} = sub
{
    my @loc = caller(1);
    CORE::die "Warning generated at line $loc[2] in $loc[1]:\n", @_, "\n";
};


# We need three arguments: the config, the id of the directory to mark the
# latest snapshot in, and the timestamp
if(scalar(@ARGV) == 3) {

    # Ensure the config file is valid, and exists
    my ($configfile) = $ARGV[0] =~ /^(\w+)$/;
    faillover("ERROR[marksnapshot]: The specified config file name is not valid, or does not exist")
        if(!$configfile || !-f "$path/config/$configfile.cfg");

    # Bomb if the config file is not at most 600
    my $mode = (stat("$path/config/$configfile.cfg"))[2];
    fallover("ERROR[marksnapshot]: $configfile.cfg must have at most mode 600.\nFix the permissions on $configfile.cfg and try again.\n", 77)
        if($mode & 07177);

    # Load the configuration
    my $config = ConfigMicro -> new("$path/config/$configfile.cfg")
        or fallover("ERROR[marksnapshot]: Unable to load configuration. Error was: $ConfigMicro::errstr\n", 74);


    # check that the second argument - the directory id - is actually numeric
    if($ARGV[1] =~ /^\d+$/) {

        # Check that the directory exists, we don't want to do anything if it doesn't
        if($config -> {"directory.$ARGV[1]"}) {

            # Check that the third argument is numeric
            if($ARGV[2] =~ /^\d+$/) {

                # Work out what the mountpoint for the directory is...
                my $base = $config -> {"directory.$ARGV[1]"} -> {"base"};
                $base = $config -> {"server"} -> {"base"} if(!$base);

                my $mountpoint = path_join($base, $config -> {"directory.$ARGV[1]"} -> {"remotedir"});

                # Okay, make sure that the directory exists
                if(-d $mountpoint) {
                    # Now we need to grab the metafile
                    my $metafile = ConfigMicro -> new(path_join($mountpoint, ".tardis_meta"));
                    if($metafile) {

                        # Update the latest backup entry
                        $metafile -> {"snapshots"} -> {"backup.0"} = $ARGV[2];

                        # And save...
                        $metafile -> write(undef, 1)
                            or fallover("ERROR[marksnapshot]: Unable to write backup metafile. Error was: ".$ConfigMicro::errstr."\n");

                        print "Snapshot timestamped successfully.\n";
                    } else {
                        fallover("ERROR[marksnapshot]: Unable to open backup metafile. Error was: ".$ConfigMicro::errstr."\n");
                    }
                } else { # if(-d $mountpoint) {

                    fallover("ERROR[marksnapshot]: backup directory does not exist. This should not happen.\n", 74);
                }

            } else { # if($ARGV[2] =~ /^\d+$/) {
                fallover("ERROR[marksnapshot]: timestamp be numeric.\n", 64);
            }
        } else { # if($config -> {"directory.$ARGV[1]"}) {
            fallover("ERROR[marksnapshot]: The specified directory id is not valid.\n");
        }
    } else { # if($ARGV[1] =~ /^\d+$/) {
        fallover("ERROR[marksnapshot]: directory id must be numeric.\n", 64);
    }
} else { # if(scalar(@ARGV) == 3) {
    fallover("ERROR[marksnapshot]: Incorrect number of arguments.\nUsage: marksnapshot.pl <config> <directory id> <timestamp>\n", 64);
}
