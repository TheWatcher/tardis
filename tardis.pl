#!/usr/bin/perl -w

## @file 
# Client-size script for the remote backup system. 
# This script should be run on the machine containing the resources to
# back up on the remote system. It coordinates the execution of remote
# maintenance scripts, and performs the necessary dumps, packing, and
# synchronisation steps required to back up local content to the remote
# backup system.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 3.7
# @date    12 December 2010
# @copy    2010, Chris Page &lt;chris@starforge.co.uk&gt;
#

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

use POSIX qw(strftime);  # Required to format the timestamp
use FindBin;             # Work out where we are
my $path;
BEGIN {
    $ENV{"PATH"} = "/bin:/usr/bin"; # safe path.

    # $FindBin::Bin is tainted by default, so we may need to fix that
    # NOTE: This may be a potential security risk, but the chances
    # are honestly pretty low... 
    if ($FindBin::Bin =~ /(.*)/) {
        $path = $1;
    }
}
use lib "$path/modules"; # Add the script path for module loading

# Custom modules to handle configuration settings and backup operations
use ConfigMicro; 
use BackupSupport qw(fallover path_join start_log stop_log write_log humanise);

$SIG{__WARN__} = sub
{
    my @loc = caller(1);
    CORE::die "Warning generated at line $loc[2] in $loc[1]:\n", @_, "\n";
};


## @fn $ mysql_backup($dumpname, $dbname, $username, $password, $maxsize, $config)
# Back up the specified database, writing a bzip2 compressed version of
# the sql dump to the backup machine. This will dump the specified
# mysql database (or all databases, if the db name is not specified),
# pack the resulting dump, and copy it to the remote backup system.
#
# @param dumpname The name of the dump file, will have the timestamp appended.
# @param dbname   The name of the database to dump. All databases are
#                 dumped into one big dump file if this is '' or undef.
# @param username The username to connect to the database with.
# @param password The password to use for the database connection.
# @param config   A reference to the global config object.
# @return A string containing progress information.
sub mysql_backup {
    my ($dumpname, $dbname, $username, $password, $config) = @_;
    my $result = "";

    # Work out the destination name
    my $filename = path_join($config -> {"client"} -> {"tmpdir"}, $dumpname.'-'.$config -> {"timestamp"}.'.sql');

    # If the database name is '' then we want to dump all databases
    if(!$dbname) {
        $result .= "Dumping all databases to $filename\n";
        $result .= `$config->{paths}->{mysql} -u $username --password=$password -Q -C -A -a -e > $filename`;
    
    # Otherwise, we just want that one database...
    } else {
        $result .= "Dumping $dbname to $filename\n";
        $result .= `$config->{paths}->{mysql} -u $username --password=$password -Q -C -a -e $dbname > $filename`;
    }

    my $starttime = time();
    $result .= "Starting database dump at ".strftime("%Y%m%d-%H%M", localtime(starttime))."\n";
    
    # In either event, pack it
    $result .= `$config->{paths}->{bzip2} $filename`;

    # Determine how large the file is
    my $dumpsize = -s "$filename.bz2";

    if($dumpsize) {
        $result .= "Compressed dump size: ".humanise($dumpsize)."\n";

        # Clean up enough space for the backup
        $result .= "Checking remote server has space for the backup...\n";
        my $clean = `$config->{paths}->{ssh} $config->{server}->{ssh} '$config->{paths}->{clean} $config->{configname} $dumpsize 2>&1'`;
        $result .= $clean;
        $result .= "Remote check complete.\n";

        # If the cleanup result is an error, do nothing
        if($clean =~ /ERROR:/) {
            $result .= "ERROR: Remote check reported one or more errors. Aborting database backup.\n";
        } else {
            # Otherwise, copy the dump over
            $result .= "Copying $filename.bz2 to backup server\n";
            $result .= `$config->{paths}->{scp} $filename.bz2 $config->{server}->{dbdump} 2>&1`;
        
            # Now remove the dump
            unlink("$filename.bz2")
                or $result .= "WARNING: Unable to remove $filename.bz2: $!\n";

            $result .= "Dump complete.\n";
        }
    } else {
        $result .= "ERROR: Unable to determine the size of $filename.bz2. Giving up.\n";
    }

    my $stoptime = time();
    my ($esec, $emin) = (localtime($stoptime - $starttime))[0,1];
    $result .= "Finished database dump at ".strftime("%Y%m%d-%H%M", localtime(endtime)).sprintf(" (took %02dmin %02dsec)\n", $emin, $esec);;

    return $result;
}



## @fn $ directory_backup($id, $config)
# Back up the specified directory to the remote server using rsync.
#
# @param id     The id of the directory to back up.
# @param config A reference to the global config object.
# @return A string containing progress information.
sub directory_backup {
    my ($id, $config) = @_;
    
    my $result .= "Backing up ".$config -> {"directory.$id"} -> {"name"}."...\n";

    my $starttime = time();
    $result .= "Starting directory backup at ".strftime("%Y%m%d-%H%M", localtime(starttime))."\n";

    # Some variables to make life easier...
    my $localdir = $config -> {"directory.$id"} -> {"localdir"};

    # Work out where the destination should be
    my $dest = path_join($config -> {"server"} -> {"path"}, $config -> {"directory.$id"} -> {"remotedir"}, "backup.0");

    # Do nothing if the localdir does not exist!
    return $result."ERROR: local directory ".$config -> {"directory.$id"} -> {"localdir"}." does not exist (or is not a directory)!\n"
        unless(-d $config -> {"directory.$id"} -> {"localdir"});

    # Try to mount the remote backup
    my $mountres = `$config->{paths}->{ssh} $config->{server}->{ssh} '$config->{paths}->{dirctrl} $config->{configname} $id mount 2>&1'`;
    $result .= $mountres;

    if($mountres =~ /ERROR:/) {
        $result .= "ERROR: Remote system unable to mount image.\n";
    } else {
        $result .= "Remote image mounted successfully.\n";

        # Build any excludes needed
        my $exclude = "";
        if($config -> {"directory.$id"} -> {"exclude"}) {
            my @excludes = split(/,/,$config -> {"directory.$id"} -> {"exclude"});

            # Build up a series of --exclude arguments
            foreach my $rule (@excludes) {
                $exclude .= " --exclude='$rule'";
            }
        }

        # If the config has an exclude file set, record it.
        $exclude .= " --exclude-from='".$config -> {"directory.$id"} -> {"excludefile"}."'"
            if($config -> {"directory.$id"} -> {"excludefile"} && -f $config -> {"directory.$id"} -> {"excludefile"});

        # now we need to work out how much data will be transferred, so we know how much to delete
        $result .= "Calculating how much data will be transferred.\n";
        my $trans = `$config->{paths}->{rsync} -az --delete $exclude --dry-run --stats --rsync-path="$config->{paths}->{sursync}" $localdir $dest 2>&1`;

        # Parse out the amount to be transferred
        my ($update) = $trans =~ /^Total transferred file size: (\d+) bytes$/m;

        # If we can't determine the file size, something may be wrong
        if(defined($update)) {
            $result .= "Incrementing remote backup, $update bytes required for current backup.\n";
            my $inc  = `$config->{paths}->{ssh} $config->{server}->{ssh} '$config->{paths}->{shift} $config->{configname} $id $update 2>&1'`;
            $result .= $inc;
        
            # Do nothing if there were errors
            if($inc =~ /ERROR:/) {
                $result .= "ERROR: Remote system reported one or more errors. Aborting directory backup.";
                
                # Otherwise go ahead and rsync
            } else {
                $result .= "Updating remote backup.\n";
                $result .= `$config->{paths}->{rsync} -avz --delete $exclude --stats --rsync-path="$config->{paths}->{sursync}" $localdir $dest 2>&1`;
                $result .= "Remote sync completed.\n";

                # and now mark the update
                $result .= `$config->{paths}->{ssh} $config->{server}->{ssh} '$config->{paths}->{mark} $config->{configname} $id $config->{starttime} 2>&1'`;
            }
        } else {
            $result .= "Unable to determine rsync transfer amount. Backup aborted for safety.\n";
        }

        # Try to unmount the remote image
        my $umountres = `$config->{paths}->{ssh} $config->{server}->{ssh} '$config->{paths}->{dirctrl} $config->{configname} $id umount 2>&1'`;
        $result .= $umountres;

        if($mountres =~ /ERROR:/) {
            $result .= "ERROR: Remote system unable to unmount image.\n";
        } else {
            $result .= "Remote image unmounted successfully.\n";
        }
    }

    my $stoptime = time();
    my ($esec, $emin) = (localtime($stoptime - $starttime))[0,1];
    $result .= "Finished directory backup at ".strftime("%Y%m%d-%H%M", localtime(endtime)).sprintf(" (took %02dmin %02dsec)\n", $emin, $esec);;

    return $result."\n";
}


# We need one argument - the config name
if(scalar(@ARGV) == 1) {

    # Ensure the config file is valid, and exists
    my ($configfile) = $ARGV[0] =~ /^(\w+)$/;
    fallover("ERROR: The specified config file name is not valid, or does not exist")
        if(!$configfile || !-f "$path/config/$configfile.cfg");

    # Bomb if the config file is not at most 600
    my $mode = (stat("$path/config/$configfile.cfg"))[2];
    fallover("ERROR: $configfile.cfg must have at most mode 600.\nFix the permissions on $configfile.cfg and try again.\n", 77)
        if($mode & 07177);

    # Load the configuration 
    my $config = ConfigMicro -> new("$path/config/$configfile.cfg")
        or fallover("ERROR: Unable to load configuration. Error was: $ConfigMicro::errstr\n", 74);

    # Store the config name for later
    $config -> {"configname"} = $configfile;

    # Timestamp for all operations that need it. We also need to store the start time
    # so we can work out execution duration.
    $config -> {"starttime"} = time();
    $config -> {"timestamp"} = strftime("%Y%m%d-%H%M", localtime($config -> {"starttime"}));

    # Convenience settings for server operations
    $config -> {"server"} -> {"ssh"}     = $config -> {"server"} -> {"user"}.'@'.$config -> {"server"} -> {"hostname"};
    $config -> {"server"} -> {"path"}    = $config -> {"server"} -> {"ssh"}.':'.$config -> {"server"} -> {"base"};
    $config -> {"server"} -> {"dbdump"}  = path_join($config -> {"server"} -> {"path"}, $config -> {"server"} -> {"dbdir"});


    # This is where things actually start. First, start building up the email
    my $email = "From: $config->{email}->{sender}\n";
    $email .= "To: $config->{email}->{recipient}\n";
    $email .= "Subject: $config->{email}->{subject} ($config->{timestamp})\n\n";
    $email .= "This is the backup script on $config->{client}->{name} run at $config->{timestamp}.\n\n";
    
    # Turn on logging from this point, if needed.
    $email .= start_log($config -> {"client"} -> {"logfile"}, $config -> {"timestamp"}, $config -> {"client"} -> {"logcount"});

    # Check that the remote server is there and lets us log in first
    my $check = `$config->{paths}->{ssh} $config->{server}->{ssh} '$config->{paths}->{echo} "$config->{timestamp}"'`;

    # If the result of the ssh is the timestamp (or contains it, just in case of MOTDness)
    # then we've got a successful login. This doesn't guarantee the backup will work, but
    # it makes it vastly more likely to succeed than not being able to log in at all...
    if($check =~ /^$config->{timestamp}/m) {
        my $abort = 0;

        # Process all the database entries....
        write_log($email, "Backing up databases...\n");
        foreach my $key (sort(keys(%$config))) {
            # Only process actual database entries...
            next unless($key =~ /^database.\d+$/);
            
            if($config -> {$key} -> {"type"} eq "mysql") {
                my $res =mysql_backup($config -> {$key} -> {"dumpname"},
                                      $config -> {$key} -> {"dbname"},
                                      $config -> {$key} -> {"username"},
                                      $config -> {$key} -> {"password"},
                                      $config);
                write_log($email, $res);

                if($res =~ /ERROR:/) {
                    $abort = 1;
                    write_log($email, "FATAL: Error detected during $key backup. Aborting.\n");
                    last;
                }
            }
        }
        write_log($email, "Database backup completed.\n\n");
        
        if(!$abort) {
            # Process all the backup directories.
            write_log($email, "Backing up directory trees...\n");
            foreach my $key (sort(keys(%$config))) {
                # Only process actual directory entries...
                next unless($key =~ /^directory.(\d+)$/);
                my $dirid = $1;
                
                my $res = directory_backup($dirid, $config);
                write_log($email,$res);

                if($res =~ /ERROR:/) {
                    $abort = 1;
                    write_log($email, "FATAL: Error detected during $key backup. Aborting.\n");
                    last;
                }
            }
            write_log($email, "Directory backup completed.\n\n");
        }

    # If the result of the login check was not the timestamp, there's a problem...
    } else { # if($check =~ /^$config->{timestamp}/m) {
        write_log($email, "Unable to log into remote server. The following response was received when attempting to log in:\n$check\nBackup failed.\n");
    }

    stop_log($email, $config -> {"starttime"});

    # Send the email to the admin, with a fallback of printing to STDERR if
    # sendmail doesn't want to work for some reason.
    my $sendmail_cmd  = "|".$config -> {"paths"} -> {"mail"}." -t -f ".$config -> {"email"} -> {"sender"};
    if(open(MAIL, $sendmail_cmd)) {
        print MAIL $email;
        close(MAIL);
    } else {
        print STDERR "Unable to open sendmail pipe.\n    Error was: $!\n";
        print STDERR "Contents of email would be:\n",$email;
    }
} else { # if(scalar(@ARGV) == 1) {
    fallover("Usage: tardis.pl <config>\n", 64);
}
