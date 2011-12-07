## @file
# Implementation of backup support functionality. This file contains the code
# needed to support the backup operations and maintenance work done by the
# other scripts.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 2.1
# @date    14 December 2010
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
package BackupSupport;

require Exporter;
use Cwd qw(getcwd chdir);
use POSIX qw(strftime);
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw();
our @EXPORT_OK = qw(path_join humanise dehumanise humanise_minutes is_number start_log stop_log write_log fallover df write_pid read_pid remove_pid);
our $VERSION   = 1.0;

# -----------------------------------------------------------------------------
#  Internal stuff

## @var FILEHANDLE loghandle
# The filehandle to which logs should be written.
my $loghandle = undef;

# -----------------------------------------------------------------------------
#  General utility functions


## @fn $ path_join(@fragments)
# Take an array of path fragments and will concatenate them together with '/'s
# as required. It will ensure that the returned string *DOES NOT* end in /
#
# @param fragments The path fragments to join together.
# @return A string containing the path fragments joined with forward slashes.
sub path_join {
    my @fragments = @_;

    my $result = "";
    foreach my $fragment (@fragments) {
        $result .= $fragment;
        # append a slash if the result doesn't end with one
        $result .= "/" if($result !~ /\/$/);
    }

    # strip the trailing / if there is one
    return substr($result, 0, length($result) - 1) if($result =~ /\/$/);
    return $result;
}


## @fn $ humanise($number)
# Convert a number in bytes into a more easily read string. This will take a
# number in bytes and output a string containing the equivalent translated
# into KB, MB, or GB depending uppon the size of the number.
#
# @param number The number of bytes.
# @return A human readable version of the supplied number.
sub humanise {
    my $number = shift;

    # Less than 1K, so return as straight bytes
    if($number < 1024) {
        return $number."B";

    # Less than 1MB but at least 1K, return in KB
    } elsif($number < 1048576) {
        # Fractional KB are dropped, they're not worth bothering with
        return sprintf("%dK", $number / 1024);

    # 1MB or more, but less than 1GB, return in MB
    } elsif($number < 1073741824) {
        # This time retain a small amount of fractional information
        my $newnum = sprintf("%.1f", $number / 1048576);
        $newnum =~ s/\.0//; # strip the trailing .0 if there is one
        return $newnum."M";

    # 1GB or over, return as GBs.
    } else {
        # Again, retain a decimal of fractional information if needed.
        my $newnum = sprintf("%.1f", $number / 1073741824);
        $newnum =~ s/\.0//; # strip the trailing .0 if there is one
        return $newnum."G";
    }
}


## @fn $ humanise_minutes($number)
# convert a number of minutes to years/months/weeks/days/hours. This will take
# the specified number of minutes and output a string containing the number of
# years, months, weeks, and days it corresponds to.
#
# @param number The number of minutes to convert.
# @return A string containing the minutes in a human readable form
sub humanise_minutes {
    my $number = shift;
    my ($mins, $hours, $days, $weeks);
    my $result = "";

    $mins = $number % 60;
    $number  = ($number - $mins) / 60;

    if($number) {
        $hours  = $number % 24;
        $number = ($number - $hours) / 24;

        if($number) {
            $days = $number % 7;
            $weeks = ($number - $days) / 7;
        }
    }

    if($weeks) { $result .= $weeks." week"  .($weeks > 1 ? "s" : ""); }
    if($days) {
        $result .= ", " if($result);
        $result .= $days ." day"   .($days  > 1 ? "s" : "");
    }

    if($hours) {
        $result .= ", " if($result);
        $result .= $hours." hour"  .($hours > 1 ? "s" : "");
    }

    if($mins) {
        $result .= ", " if($result);
        $result .= $mins ." minute".($mins  > 1 ? "s" : "");
    }

    return $result;
}


## @fn $ dehumanise($number)
# Given a number (which may end in K, M, G, or KB, MB, GB) return a number that
# is the equivalent in bytes. This is the opposite of the humanise() function,
# in that it can, for example, take a number like 20G and return the value
# 21474836480.
#
# @param number The number to convert to bytes.
# @param The machine-usable version of the number.
sub dehumanise {
    my $number = shift;

    # pull out the number, and the multiplier if present
    my ($num, $multi) = $number =~ /^(\d+(?:\.\d+)?)(K|M|G)?B?$/;

    # If no multiplier is present or recognised, return the number as-is
    if(!$multi) {
        return $num;

    # Otherwise, deal with KB, MB, and GB.
    } elsif($multi eq "K") {
        return $num * 1024;
    } elsif($multi eq "M") {
        return $num * 1048576;
    } elsif($multi eq "G") {
        return $num * 1073741824;
    }
}


## @fn $ is_number($number)
# Determine whether the specified number is valid, and could be passed to dehumanise().
# This is a convenience function to simplify the process of identifying values that
# can be processed.
#
# @param number The number to test.
# @return true if the number is valid, undef otherwise.
sub is_number {
    my $number = shift;

    # Allow numbers to be of the form <digits>[.<digits>] followed by an optional
    # K, M or G and then an optional B (the B is always going to be implicit and
    # discarded anyway)
    return 1 if($number =~ /^\d+(\.\d+)?(K|M|G)?B?$/);

    return undef;
}


## @fn @ df($path, $config)
# Obtain the size, usage, and free space on the device corresponding to the specified path.
# This will run df on the specified path and parse out the device size, used space and
# free space, and the number of free inodes. On filesystems that do not limit inodes (like
# reiserfs) this will always return -1 for the free inodes.
#
# @param path   The path to run df on.
# @param config A reference to the system configuration hash.
# @return An array of five values: the device size, used space, and free space, all in bytes, and
#         the number of inodes and free inodes available.
sub df {
    my $path   = shift;
    my $config = shift;

    # Work out the space used, free, etc...
    my $df_stats  = `$config->{paths}->{df} -B 1 $path`;
    my ($msize, $mused, $mfree) = $df_stats =~ m{^/dev/\S+?\s+(\d+)\s+(\d+)\s+(\d+)}m;

    # Now work out inodes...
    $df_stats = `$config->{paths}->{df} -i $path`;
    my ($inodes, $ifree) = $df_stats =~ m{^/dev/\S+?\s+(\d+)\s+\d+\s+(\d+)}m;

    # Some filesystems do not limit inodes, so set the number free to -1 in that case
    $ifree = -1 if($inodes == 0);

    return ($msize, $mused, $mfree, $inodes, $ifree);
}


# -----------------------------------------------------------------------------
#  Logging functions (primarily intended as client-side)

## @fn $ start_log($logname, $timestamp, $logcount)
# Create a new log file, removing any existing logs that exceed the
# specified log count. This will attempt to remove any old logs before
# opening the new log.
#
# @param logname   The base name for the log, will have the timestamp appended, can include path.
# @param timestamp The timestamp to set for the log
# @param logcount  The number of log files to retain
# @return A status message indicating log open status.
sub start_log {
    my $logname   = shift;
    my $timestamp = shift;
    my $logcount  = shift;
    my $result    = "--== Logging started at $timestamp ==--\n\n";

    # Do nothing if we have no logname
    return "Logging disabled.\n" if(!$logname);

    # First, we need to remove all but the latest $logcount logs
    my @files = sort glob("$logname.*");

    # There's no point in doing anything with the files, unless there are more
    # that the log count limit available...
    if(scalar(@files) > $logcount) {
        $result .= "Removing ".(scalar(@files) - $logcount)." old log file\n";
        # remove from $logcount on..
        for(my $kill = $logcount; $kill < scalar(@files); ++$kill) {
            unlink $files[$kill]
                or $result .= "Unable to remove ".$files[$kill].": $!\n";
        }
    }

    # Attempt to open the log file...
    if(open($loghandle, "> $logname-$timestamp")) {
        $result .= "Opened log file $logname-$timestamp successfully.\n\n";
        print $loghandle $result;
    } else {
        $loghandle = undef; # Just to be certain...
        $result .= "Unable to open log file $logname-$timestamp: $!\n\n";
    }

    return $result;
}


## @fn void stop_log($buffer, $starttime)
# Attempt to close the log file if it has been opened.
#
# @param buffer    A reference to the buffer to write status messages to.
# @param starttime The time, in seconds past the epoc, when logging started.
sub stop_log(\$$) {
    my $buffer    = shift;
    my $starttime = shift;

    # Only do anything useful if there is no log file to write to
    if($loghandle) {
        # Work out stop information
        my $stoptime = time();
        my ($esec, $emin) = (localtime($stoptime - $starttime))[0,1];

        # Stop timestamp
        my $stopstamp = strftime("%Y%m%d-%H%M", localtime($stoptime));
        my $message = sprintf("--== Logging stopped at %s (execution took %02dmin %02dsec) ==--\n", $stopstamp, $emin, $esec);

        write_log($buffer, $message);
        close($loghandle);
    }
}


## @fn void write_log($buffer, $message)
# Write the specified message to the buffer, and to the log file if it is open.
#
# @param buffer  A reference to the buffer to write the message to.
# @param message The message to write to the buffer and log file.
sub write_log(\$$) {
    my $buffer  = shift;
    my $message = shift;

    # If we have a log file available, write to it
    print $loghandle $message if($loghandle && $message);

    # And append to the buffer
    $$buffer .= $message if($buffer);
}

## @fn void fallover($message, $code, $pidfile)
# Print an error message to stderr and then exit with the specified code. This
# behaves somewhat like die except that it does not need $! to be set and it
# is logfile-aware (the message is echoed to the log before it is closed, if the
# log has been opened.)
#
# @param message  The message to print to STDERR.
# @param code     Optional code to return via exit. If not specified, the value
#                 in $! is returned, unless that is zero, in which case 255 is
#                 returned.
# @param pidfile  The name of the PID file to remove. If not specified, nothing is done.
sub fallover {
    my $message = shift;
    my $code    = shift;
    my $pidfile = shift;
    my $buffer;

    # Fix up code to be something non-zero (either $! or 255
    $code = $! ? $! : 255 if(!$code);

    stop_log($buffer, $message) if($loghandle);
    print STDERR $message;

    remove_pid($pidfile) if($pidfile);
    exit($code);
}



# -----------------------------------------------------------------------------
#  PID file support for exclusivity.

## @fn void write_pid($filename)
# Write the process id of the current process to the specified file. This will
# attempt to open the specified file and write the current processes' ID to
# it for use by other processes.
#
# @param filename The name of the file to write the process ID to.
sub write_pid {
    my $filename = shift;

    open(PIDFILE, "> $filename")
        or die "FATAL: Unable to open PID file for writing: $!\n";

    print PIDFILE $$;

    close(PIDFILE);
}


## @fn $ read_pid($filename)
# Attempt to read a PID from the specified file. This will read the file, if possible,
# and verify that the content is a single string of digits.
#
# @param filename The name of the file to read the process ID from.
# @return The process ID. This function will die on error.
sub read_pid {
    my $filename = shift;

    open(PIDFILE, "< $filename")
        or die "FATAL: Unable to open PID file for reading: $!\n";

    my $pid = <PIDFILE>;
    close(PIDFILE);

    chomp($pid); # should not be needed, but best to be safe.

    my ($realpid) = $pid =~ /^(\d+)$/;

    die "FATAL: PID file does not appear to contain a valid process id.\n"
        unless($realpid);

    return $realpid;
}


## @fn void remove_pid($filename)
# Remove the specified PID file. This will remove the specified PID file if
# it exists.
#
# @param filename The name of the file to read the process ID from.
sub remove_pid {
    my $filename = shift;

    unline($filename)
        or die "Unable to remove PID file: $filename.\n";
}

1;
