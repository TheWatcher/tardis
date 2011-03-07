#!/usr/bin/perl -wT

## @file
# Server-side script to perform database cleanup tasks for remote backups.
# This script takes the amount of data that needs to be sent to do the 
# next backup, and attempts to determine whether there is enough space to 
# store the new data, and if there is not it will try to delete old dumps 
# to make sufficient space.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 3.5
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
use ConfigMicro; 
use BackupSupport qw(is_number humanise humanise_minutes dehumanise fallover path_join df);

$SIG{__WARN__} = sub
{
    my @loc = caller(1);
    CORE::die "Warning generated at line $loc[2] in $loc[1]:\n", @_, "\n";
};


## @fn $ database_cleanup($path, $required, $config)
# Attempt to clean out enough old database backups to store the required bytes
# in the database directory. This will determine whether there is enough space
# in the database backup directory to store the specified number of bytes. If
# there is not, it will delete old backups in reverse chronological order until
# it either deletes enough, or no more backups can be deleted.
#
# @param path     The database directory path. This function assumes that the
#                 presence and validity of this directory have been verified.
# @param required The number of bytes that need to be stored in the directory.
# @param confif   A reference to the global configuration hash.
# @rethrn true if there is enough space in the backup directory to store the
#         required data, false if a problem occured.
sub database_cleanup {
    my $path     = shift;
    my $required = shift;
    my $config   = shift;

    # Determine whether there's enough space already. First we need the 
    # used space...
    my $du =  `$config->{paths}->{du} -sB 1 $path 2>&1`;
    my ($used) = $du =~ /^(\d+)/;

    # We need to give up if we can't determine the used space
    if(!defined($used)) {
        print "ERROR: Unable to determine how much space has been used in the database directory.\n";
        return 0;
    }
    
    my $limit = dehumanise($config -> {"server"} -> {"dbsize"});

    # Get the list of files, ordered by descendng age (oldest first)
    my $ls = `$config->{paths}->{ls} -1rt --color=none $path`;

    # was the ls sucessful?
    if(($? & 0xFF00) >> 8 != 0) {
        print "ERROR: Unable to obtain a list of files in the database backup directory.\nERROR: ls returned: $ls";
        return 0;
    }

    # convert the list to something useful...
    my @files = split /^/,$ls;

    foreach my $file (@files) {
        chomp($file);
    }

    # Okay, is there enough space already? If so, we can finish right now...
    if(($used + $required) <= $limit) {
        printf("Database dir has %s free of %s (%d%% used), %s (%d%% used) after requested backup.\n",
               humanise($limit - $used), $config -> {"server"} -> {"dbsize"}, 100 * ($used / $limit),
               humanise($limit - ($used + $required)), 100 * (($used + $required) / $limit));
        
        # Work out the average file size
        my $fileavg = ($used + $required) / (scalar(@files) + 1);
        printf("Including current, there are %d backups (%s), average is %s.\n", scalar(@files), humanise_minutes(scalar(@files) * $config -> {"client"} -> {"backupfreq"}), humanise($fileavg));

        # how many whole backups can we fit in the remaining space at the current rate?
        my $backspace = int(($limit - ($used + $required)) / $fileavg);

        printf("At current size, there is space for %d backups (%s worth).\n", $backspace, humanise_minutes($backspace * $config -> {"client"} -> {"backupfreq"}));

        return 1;
    }

    # Okay, there isn't enough space. how much do we need?
    my $freetarget = ($used + $required) - $limit;

    # now drop the forced retain entries if there is a limit set
    splice(@files, -1 * $config -> {"server"} -> {"forcedbs"}) 
        if($config -> {"server"} -> {"forcedbs"});

    # First pass: check whether or not we can delete enough...
    print "Backup cleanup will remove:\n";
    my ($pos, $freed) = (0, 0);
    while($freed < $freetarget && $pos < scalar(@files)) {
        my $fullname = path_join($config -> {"server"} -> {"base"}, $config -> {"server"} -> {"dbdir"}, $files[$pos++]);
        $freed += -s $fullname;
	print "$fullname\n";
    }

    # If we can't free up enough, just give up
    if($freed < $freetarget) {
        print "ERROR: Unable to free up enough space for the requested database backup.\n";
        return 0;
    }

    # Okay, try it for real. Note that this MAY NOT free up as much the previous loop might
    # have suggested if there is a problem with deleting an file!
    ($pos, $freed) = (0, 0);
    while($freed < $freetarget && $pos < scalar(@files)) {
	my ($name) = $files[$pos] =~ /^(\w+-\d+-\d+\.sql\.bz2)$/;
        next if(!$name); # give up if the name does not conform to expectations

        my $fullname = path_join($config -> {"server"} -> {"base"}, $config -> {"server"} -> {"dbdir"}, $name);
        my $size = -s $fullname;

        # If the delete works, add the size to the free total, otherwise print a warning...
        if(unlink($fullname)) {
            $freed += $size;
        } else {
            print "WARNING: Unable to delete '",$files[$pos],"': $!\n";
        }

        ++$pos;
    }
 
    # Do we have enough freed?
    if($freed >= $freetarget) {
        printf("Cleanup has freed %s by deleting %d old backups. %s (%d%%) will remain after requested backup.\n",
               humanise($freed), $pos,
               humanise(dehumanise($config -> {"server"} -> {"dbsize"}) - (($used - $freed) + $required)),
               100 * ((($used - $freed) + $required) / dehumanise($config -> {"server"} -> {"dbsize"})));

        # How many files do we have left?
        my $fcount = `$config->{paths}->{ls} -1 $path | $config->{paths}->{wc} -l`;
        
        if($fcount) {
            ++$fcount;
            printf("%d backup files are currently retained, covering %s\n", $fcount, humanise_minutes($fcount * $config -> {"client"} -> {"backupfreq"}));
        }

        return 1;
    }
   
    # Can't free up enough, boo :(
    return 0;
}


## @fn $ check_filespace($path, $required, $config)
# Determine whether there is enough physical space on the drive for the required
# bytes. This will check whether there is enough free space on the drive to
# store the required space, rather than just relying on the size of the db dir.
#
# @note It is possible that this will report that there is enough space to store
#       the backup, but the backup may still fill the drive. This is unlikely
#       in the situation where the backup script is the only process writing to
#       the drive, but if the drive is shared with other processes and data
#       is written to the drive after this is called, later backups may fail.
#       Rule of thumb: don't use the backup drive for anything else! (not that
#       you should be doing that <i>anyway</i>!)
#
# @param path     The database directory path. This function assumes that the
#                 presence and validity of this directory have been verified.
# @param required The number of bytes that need to be stored in the directory.
# @param confif   A reference to the global configuration hash.
# @rethrn true if there is enough space in the backup directory to store the
#         required data, false if there is not.
sub check_filespace {
    my $path     = shift;
    my $required = shift;
    my $config   = shift;

    # Work out how much space there is on the drive
    my ($size, $used, $free) = df($path, $config);

    fallover("ERROR: bad response from df for $path.\n", 75)
        if(!defined($size) || !defined($used) || !defined($free));

    # Is it enough?
    return $free >= $required;
}


# We need two arguments - the config name, and the amount of required space
if(scalar(@ARGV) == 2) {

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


    # Check that the backup directory exists, reap the contents if it does
    my $dbpath = path_join($config -> {"server"} -> {"base"}, $config -> {"server"} -> {"dbdir"});
    if(-d $dbpath) {

        # Check that the required size is numeric, with an optional trailing K/M/G 
        if(is_number($ARGV[1])) {
            
            # Try to free up enough space for the backup
            if(database_cleanup($dbpath, dehumanise($ARGV[1]), $config)) {
                
                # Now verify that real space exists!
                if(!check_filespace($dbpath, dehumanise($ARGV[1]), $config)) {
                    fallover("ERROR: insufficient free space on device for requested backup.\n", 75);
                }

            # Can't free up enough space, fall over with an error...
            } else {
                fallover("ERROR: cleanup failed.\n", 75);
            }

        # Back required space argument
        } else { # if(is_number($ARGV[1])) {
            fallover("ERROR: The specified required size is not a valid number.\n", 64);
        }

    # The backup directory doesn't exist
    } else { # if(-d $dbpath) {
        # Can we create the directory?
        if(mkdir($dbpath)) {
            
            # Should existnow , is there space?
            if(!check_filespace($dbpath, dehumanise($ARGV[1]), $config)) {
                fallover("ERROR: insufficient free space on device for requested backup.\n", 75);
            }
        } else {
            fallover("ERROR: Backup directory is not valid: directory does not exist, and can not be created ($!).\n", 75);
        }
    }

# Incorrect number of arguments
} else { # if(scalar(@ARGV) == 2) {
    fallover("ERROR: Incorrect number of arguments.\nUsage: cleanup.pl <config> <required space>\n", 64);
}
