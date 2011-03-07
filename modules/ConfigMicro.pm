## @file
# This file contains the implementation of a compact, simple congifuration
# loading and saving class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 2.1
# @date    13 August 2010
# @copy    2010, Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class ConfigMicro
# A simple configuration class intended to allow ini files to be read and saved. This
# provides the means to read the contents of an ini file into a hash and saving such a
# hash out as an ini file.
#
# @par Example
#
# Given an ini file of the form
# <pre>[sectionA]
# keyA = valueA
# keyB = valueB
#
# [sectionB]
# keyA = valueC
# keyC = valueD</pre>
# this will load the file into a hash of the form
# <pre>{ "sectionA" => { "keyA" => "valueA",
#                   "keyB" => "valueB" },
#   "sectionB" => { "keyA" => "valueC",
#                   "keyC" => "valueD" } 
# }</pre>
package ConfigMicro;

require 5.005;
use DBI;
use strict;

our ($VERSION, $errstr);

BEGIN {
    $VERSION = 2.0;
    $errstr = '';
}

# ============================================================================
#  Constructor and basic file-based config functions

## @cmethod $ new(%args)
# Create a new ConfigMicro object. This creates an object that provides functions
# for loading and saving configurations, and pulling config data from a database. 
# Meaningful options for this are:
# filename - The name of the configuration file to read initial settings from. This
#            is optional, and if not specified you will get an empty object back.
# You may also pass in one or more initial configuration settings.
# @param args A hash of key, value pairs to initialise the object with.
# @return A new ConfigMicro object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $filename = shift;

    # Object constructors don't get much more minimal than this...
    my $self = { "__privdata" => { "modified" => 0,
                                   "filename" => $filename },
                 @_,
    };

    my $obj = bless $self, $class;

    # Return here if we have no filename to load from
    return $obj if(!$filename);

    # Otherwise, try to read the file
    return $obj if($obj -> read($filename));

    # Get here and things have gone wahoonie-shaped
    return undef;
}


## @method $ get_value($section, $name)
# Obtain the value for the given key in the specified section.
#
# @param section The section in which the key can be found.
# @param name    The name of the key to obtain.
# @return The value of the key, or "" if the key is empty
sub get_value {
    my $self    = shift;
    my $section = shift;
    my $name    = shift;

    return $self -> {$section} -> {$name} || "";
}


## @method void set_value($section, $name, $value)
# Set the value for the given key in the specified section.
#
# @param section The section in which the key can be found.
# @param name    The name of the key to set.
# @param value   The value to set for the key.
sub set_value {
    my $self    = shift;
    my $section = shift;
    my $name    = shift;
    my $value   = shift;

    $self -> {$section} -> {$name} = $value;

    # Always set modified on, well, modify...
    $self -> {"__privdata"} -> {"modified"} = 1;
}



## @method void replace_vars()
# Replace all variables in the configuration with the value they correspond to.
# This will traverse all sections and variables in the configuration, looking for
# $[section,name] markers and replacing them as needed. Note that this is a very
# simplistic system, only doing one pass and not attempting to check dependencies
# have been resolved, so if variables reference other variables, there's no 
# guarantee that they will be correctly resolved.
sub replace_vars {
    my $self = shift;

    # Process all the sections...
    foreach my $section (keys(%$self)) {
	# Only process sections, not values
	next unless(ref($self -> {$section}));

	# And all key-value pairs in the section
	foreach my $key (keys(%{$self -> {$section}})) {
	    # If the value contains a variable, replace it
	    $self -> {$section} -> {$key} =~ s/\$\[([-\w]+),([-\w]+)\]/$self->get_value($1,$2)/ge;
	}
    }
}


## @method $ read($filename)
# Read a configuration file into a hash. This will process the file identified by
# the specified filename, attempting to load its contents into a hash. Any key/value
# pairs that occur before a [section] header are added to the '_' section.
#
# @param filename The name of the file to read the config data from.
# @return True if the configuration has been loaded sucessfully, false otherwise.
sub read {
    my $self     = shift;
    my $filename = shift or return set_error("No file name provided");

    # The current section, default it to '_' in case there is no leading [section]
    my $section = "_"; 

    # TODO: should this return the whole name? Possibly a security issue here
    return set_error("Failed to open '$filename': $!")
        if(!open(CFILE, "< $filename"));

    my $counter = 0;
    my $dosub   = 0; # This will get set to true if there are variables to substitute
    while(my $line = <CFILE>) {
        chomp($line);
        ++$counter;

        # Skip comments and empty lines
        next if($line =~ /^\s*(\#|;|\z)/);

        # Handle section headers, allows for comments after the ], but [foo #comment] will
        # treat the section name as 'foo #comment'!
        if($line =~ /^\s*\[([^\]]+)\]/) {
            $section = $1;

        # Attribues with quoted values. value can contain anything other than "
        } elsif($line =~ /^\s*([-\.\w]+)\s*=\s*\"([^\"]*)\"/ ) {
            my ($key, $value) = ($1, $2);

            $self -> {$section} -> {$1} = $value;
            $dosub = 1 if(!$dosub && $value =~ /\$\[[-\w]+,[-\w]+\]/);

        # Handle attributes without quoted values. # or ; at any point will mark comments
        } elsif($line =~ /^\s*([-\.\w]+)\s*=\s*([^\#;]+)/ ) {
            my ($key, $value) = ($1, $2);

            # Trim leading/trailing space
            $value =~ s/^\s*(\S*)\s*$/$1/;

            $self -> {$section} -> {$key} = $value;
            $dosub = 1 if(!$dosub && $value =~ /\$\[[-\w]+,[-\w]+\]/);

        # bad input...
        } else {
            close(CFILE);
            return set_error("Syntax error on line $counter: '$line'");
        }
    }
    close(CFILE);

    # replace any encountered variables if there are any.
    $self -> replace_vars() if($dosub);

    return 1;
}


## @method $ text_config(@skip)
# Create a text version of the configuration stored in this ConfigMicro object. 
# This creates a string representation of the configuration suitable for writing to
# an ini file or otherwise printing. 
#
# @param skip If you specify one or more section names, the sections will not be 
#             added to the string generated by this function.
# @return A string representation of this ConfigMicro's config settings.
sub text_config {
    my $self = shift;
    my @skip = @_;
    my $result;

    my ($key, $skey);
    foreach $key (sort(keys(%$self))) {
        # Skip the internal settings
        next if($key eq "__privdata");
 
        # If we have any sections to skip, and the key is one of the ones to skip... skip!
        next if(scalar(@skip) && grep($key, @skip)); 
            
        # Otherwise, we want to start a new section. Entries in the '_' section go out
        # with no section header. 
        $result .= "[$key]\n" if($key ne "_");

        # write out all the key/value pairs in the current section
        foreach $skey (sort(keys(%{$self -> {$key}}))) {
            $result .= $skey." = \"".($self -> {$key} -> {$skey} || "")."\"\n";
        }
        $result .= "\n";
    }
    return $result;
}


## @method $ write($filename, $force, @skip)
# Save a configuration hash to a file. Writes the contents of the configuration to
# a file, formatting the output as an ini-style file.
#
# @param filename The file to save the configuration to.
# @param force    If true, the configuration is written even if it is not marked 
#                 as modified. If not specified, defaults to false.
# @param skip     An optional list of names of sections to ignore when writing the
#                 configuration.
# @return true if the configuration was saved successfully, false if a problem 
#         occurred.
sub write {
    my $self     = shift;
    my $filename = shift;
    my $force    = shift;
    my @skip     = @_;

    # fall back on the source file if needed
    $filename = $self -> {"__privdata"} -> {"filename"} if(!$filename);

    # Do nothing if the config has not been modified.
    return set_error("Configuration not modified.") if(!$force && !$self -> {"__privdata"} -> {"modified"});

    open(CFILE, "> $filename")
        or return set_error("Failed to save '$filename': $!");

    print CFILE $self -> text_config(@skip);

    close(CFILE);

    return 1;
}


# ============================================================================
#  Database config functions

## @method $ load_db_config($dbh, $table, $name, $value)
# Load settings from a database table. This will pull name/value pairs from the
# named database table, storing them in a hashref called 'config'.
#
# @param dbh      A database handle to issue queries through.
# @param table    The name of the table containing key/value pairs.
# @param name     Optional name of the table column for the key name, defaults to 'name'
# @param value    Optional name of the table column for the value, defaults to 'value'
# @return true if the configuration table was read into the config object, false
#         if a problem occurred.
sub load_db_config {
    my $self     = shift;
    my $dbh      = shift or return set_error("No database handle provided");
    my $table    = shift or return set_error("Settings table name not provided");
    my $name     = shift || "name";
    my $value    = shift || "value";

    my $confh = $dbh -> prepare("SELECT * FROM $table");
    $confh -> execute()
       or return set_error("Unable to execute SELECT query - ".$dbh -> errstr);

    my $row;
    while($row = $confh -> fetchrow_hashref()) {
        $self -> {"config"} -> {$row -> {$name}} = $row -> {$value};
    }
    
    return 1;
}


## @method $ save_db_config($dbh, $table, $name, $value)
# Save the database configuration back into the database table. This will write the
# key/value pairs inside the 'config' configuration hash back into the database.
#
# @param dbh      A database handle to issue queries through.
# @param table    The name of the table containing key/value pairs.
# @param name     Optional name of the table column for the key name, defaults to 'name'
# @param value    Optional name of the table column for the value, defaults to 'value'
# @return true if the configuration table was read into the config object, false
#         if a problem occurred.
sub save_db_config {
    my $self     = shift;
    my $dbh      = shift or return set_error("No database handle provided");
    my $table    = shift or return set_error("Settings table name not provided");
    my $name     = shift || "name";
    my $value    = shift || "value";

    my $confh = $dbh -> prepare("UPDATE $table SET `$value` = ? WHERE `$name` = ?");
    
    foreach my $key (keys(%{$self -> {"config"}})) {
        $confh -> execute($self -> {"config"} -> {$key}, $key)
            or return set_error("Unable to execute UPDATE query - ".$dbh -> errstr);
    }

    return 1;
}


# ============================================================================
#  Error functions

sub set_error { $errstr = shift; return undef; }

1;
