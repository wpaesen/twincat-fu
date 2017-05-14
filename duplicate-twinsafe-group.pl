#!/usr/bin/perl
#
# duplicate-twinsafe-group.pl
#
# A program to duplicate a TwinCAT Safety project group.
#
# Usage:
#
# duplicate-twinsafe-group.pl <Safety Project Folder> <SourceName> <TargetName>
#
# MIT License
#
# Copyright (c) 2017 Wouter Paesen
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# This script will allow you to duplicate a TwinCAT Safety project group.  The parameters
# required are : 
# - The directory in which the safety project is stored
# - The name of the original group folder (this should only be the name, not a path)
# - The name of the duplicate group folder (this should only be the name, not a path)
#
# This script will
#
# 1. Scan all the SDS definitions and create a remapping table for SDS
#    (We can not have duplicate SDS ids')
#
# 2. Scan all the GUID's in the group folder we want to copy and create
#    a remapping table for those.
#
# 3. Scan all the groupOrderId's in the project to determine the new group order
#    for the destination.
#
# 4. Create a group folder to copy into.
#
# 5. Copy all the SDS from the copy source to the copy destination, applying the
#    SDS remapping during the copy process.
#
# 6. Copy all the other files from the copy source to the copy destination.
#    During the copying also apply SDS and GUID remapping.
#
# 7. Add the new group to the safety project file.
#
# After the copying it is up to the user to open the project in the TwinCAT engineering
# interface and validate the project CRC's.
#

use File::Spec;
use File::Glob;
use File::Find;
use Data::Dumper;
use Data::GUID;
use List::Util qw(max);
use Fcntl;

use Cwd;

my ($projectfolder, $oldgroupname, $groupname) = @ARGV;

# guidmap is a hash of all the GUID's found in the application
my $guidmap = {};

my @guidfiles;
my @nonguidfiles;

my $sdsmap_prj = {};
my $sdsmap_grp = {};

my @sds_regexes;
my $highest_group_order = 0;

# check if projectfolder exists
die "$projectfolder is not a directory" unless -d $projectfolder;

# make sure projectfolder is stored as an absolute path
if (! File::Spec->file_name_is_absolute ($projectfolder)) {
		$projectfolder = File::Spec->rel2abs ($projectfolder);
}

# check if there is a file called TargetSystemConfig.xml
die "$projectfolder is not a valid TwinSAFE project" unless -f File::Spec->catfile($projectfolder, "TargetSystemConfig.xml");

# check if there is a .splcProj in the project
chdir($projectfolder) or die "Could not chdir to $projectfolder $!";

my $splc_glob = File::Spec->catfile("*.splcProj");
my @splcfiles = glob($splc_glob);

die "$projectfolder does not contain an .splcProj file" unless scalar @splcfiles > 0;

# check if the groupname is c compliant
die "$groupname is not C-Compliant" unless ($groupname =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/);
die "$oldgroupname is not C-Compliant" unless ($oldgroupname =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/);

# check if the groupfolder exists;
my $groupfolder = File::Spec->catfile($projectfolder, $groupname);
die "$groupfolder already exists" if -d $groupfolder;

# check if the oldgroupfolder exists;
my $oldgroupfolder = File::Spec->catfile($projectfolder, $oldgroupname);
die "$oldgroupfolder does not exist" unless -d $oldgroupfolder;

# According to what we know about the structure of a Safety Project GUID are never
# cross referenced between Safety Groups.   So we will iterate over all the files in
# the safety group we want to fix and replace all GUID's for them.

# iterate all the guid's in all the files if the group we want to copy.
find(\&scan_guid, $oldgroupfolder);

# generate a new GUID for each one we found
foreach my $guid (keys %{$guidmap}) {
		$guidmap->{$guid}->{'new'} = Data::GUID->new->as_string;
}

# iterate all the group order ids, before we copy.  The copied group will receive
# a group order that is 1 higher than the original one.
find(\&scan_group_order, $projectfolder);

# find all the sds used in the project but not in the group folder we are using
find(\&scan_sds, $projectfolder);

my $last_sds = max keys %{$sdsmap_prj};
print "highest valid SDS id is $last_sds\n";
print "highest group order id is $highest_group_order\n";

# create the new group folder
mkdir $groupfolder or die "Could not create group folder $groupfolder : $!";
mkdir File::Spec->catdir($groupfolder, "Alias Devices") or die "Could not create group subfolder $groupfolder : $!";

# update the group map and calculate replacement sds ids
# while we are at it also copy all the SDS definitions files from the 
# original group to the new group folder
foreach my $old_id (keys %{$sdsmap_grp}) {
		if (defined $sdsmap_prj->{$old_id}) {
				$sdsmap_grp->{$old_id}->{'new'} = ++$last_sds;
				my $new_id = $sdsmap_grp->{$old_id}->{'new'};
				my $filename = $sdsmap_grp->{$old_id}->{'file'};

				$filename =~ s/\Q$oldgroupname/$groupname/g;
				$sdsmap_prj->{$old_id}->{'newfile'} = $filename;
				
				print "remapping SDS $old_id to $new_id\n";
				$sdsmap_prj->{$sdsmap_grp->{$old_id}->{'new'}} = $sdsmap_grp->{$old_id};
				$sdsmap_grp->{$old_id}->{'newfile'} =

				copy_sds_definition ($sdsmap_grp->{$old_id}->{'file'}, $filename, $old_id, $new_id);
				
				my $map = {
						'seek' => "SdsId" . $old_id,
						'replace' => "SdsId" . $new_id
				};
				push @sds_regexes, $map;

				my $map = {
						'seek' => "sdsId=\"" . $old_id . "\"",
						'replace' => "sdsId=\"" . $new_id . "\""
				};
				push @sds_regexes, $map;
		}
}

# copy all nonguidfiles to a new path where the name of the old group is replaced by the new
# we look for sds definitions in these files and replace them in the copy process.
foreach my $infile (@nonguidfiles) {
		my $outfile =~ s/\Q$oldgroupname/$groupname/gm;

		# open the original file for reading
		open(my $fh_in, '<:encoding(UTF-8)', $infile) or die "Could not open file '$infile' $!";

		# create the original file for writing
		open(my $fh_out, '>:encoding(UTF-8)', $outfile) or die "Could not create file '$outfile' $!";

		while (my $line = <$fh_in>) {
				# apply all the SDS remapping regexes.
				foreach my $map (@sds_regexes) {
						$line =~ s/\Q$map->{'seek'}/$map->{'replace'}/g;
				}
				
				print $fh_out $line;
		}

		close ($fh_in);
		close ($fh_out);
}

# Create the replacement pattern for groupOrderId in all files we duplicate.
my $group_order_replace = sprintf("groupOrderId=\"%d\"", $highest_group_order+1);

# copy all guidfiles to a new path where the name of the old group is replaced by the new
# we look for sds definitions in these files and replace them in the copy process.
# we also look for guid's and replace them in the copy process
foreach my $infile (@guidfiles) {
		my $outfile = $infile;

		$outfile =~ s/\Q$oldgroupname/$groupname/gm;

		# open the original file for reading
		open(my $fh_in, '<:encoding(UTF-8)', $infile) or die "Could not open file '$infile' $!";

		# create the original file for writing
		open(my $fh_out, '>:encoding(UTF-8)', $outfile) or die "Could not create file '$outfile' $!";

		while (my $line = <$fh_in>) {
				# apply all the SDS remapping regexes.
				foreach my $map (@sds_regexes) {
						$line =~ s/\Q$map->{'seek'}/$map->{'replace'}/g;
				}

				# scan for GUID's 
				my @found_guids = ($line =~ /([[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12})/g);

				# remap GUID's
				foreach my $found_guid (@found_guids) {
						$line =~ s/\Q$found_guid/$guidmap->{$found_guid}->{'new'}/g;
				}

				# remap the groupOrderId
				$line =~ s/groupOrderId="[0-9]*"/$group_order_replace/g;

				print $fh_out $line;
		}

		close ($fh_in);
		close ($fh_out);
}

# open the main project file and add the necessary includes
# before we start modifying the projectfile, make a backup of it.
my $splcfile_orig = $splcfiles[0];
my $splcfile_backup = $splcfile_orig . ".bak";

unlink ($splcfile_backup) if -f $splcfile_backup;
rename($splcfile_orig, $splcfile_backup) or die "Could not move $splcfile_orig to $splcfile_backup : $!";

# open the backup file for reading
open(my $fh_in, '<:encoding(UTF-8)', $splcfile_backup) or die "Could not open file '$splcfile_backup' $!";

# create the original file for writing
open(my $fh_out, '>:encoding(UTF-8)', $splcfile_orig) or die "Could not create file '$splcfile_orig' $!";

# lines will containt all the lines we will want to insert into the file.
my @lines;

my $splcmatch = "Include=\"$oldgroupname";
my $splcmatchend = "</ItemGroup>";
		
while (my $line = <$fh_in>) {
		if ($line =~ /\Q$splcmatch/g) {
				# if this line refers to the name of the group we copy from
				my $line2 = $line;
				$line2 =~ s/\Q$oldgroupname/$groupname/g;
				push @lines, $line2;

				# Additionally if this line refers to a diagram file insert some
				# more lines to make the XML valid.
				if ($line2 =~ /Include=.(.*\.sal)\.diagram/) {
						push @lines, "     <Visible>false</Visible>\n";
						push @lines, "     <DependentUpon>$1</DependentUpon>\n";
						push @lines, "   </None>\n";
				}
		}

		if ($line =~ /\Q$splcmatchend/g) {
				# if the line we currently see constitutes the end ofr the ItemGroup XML structure
				# we insert all the lines first.
				foreach my $line2 (@lines) {
						print $fh_out $line2;
				}
		} 

		# write the original line to the output file.
		print $fh_out $line;
}

close ($fh_in);
close ($fh_out);
		
exit;

# rewrite the sds definitions in the program
sub copy_sds_definition {
		my ($infile, $outfile, $oldid, $newid) = @_;

		# open the backup file for reading
		open(my $fh_in, '<:encoding(UTF-8)', $infile) or die "Could not open file '$infile' $!";

		# create the original file for writing
		open(my $fh_out, '>:encoding(UTF-8)', $outfile) or die "Could not create file '$outfile' $!";

		my $regex_match = "<SDSID>" . $oldid . "</SDSID>";
		my $regex_replace = "<SDSID>" . $newid . "</SDSID>";

		my $regex2_match = "<ConnectionId>" . $oldid . "</ConnectionId>";
		my $regex2_replace = "<ConnectionId>" . $newid . "</ConnectionId>";
		
		while (my $line = <$fh_in>) {
				$line =~ s/\Q$regex_match/$regex_replace/g;
				$line =~ s/\Q$regex2_match/$regex2_replace/g;
				print $fh_out $line;
		}

		close ($fh_in);
		close ($fh_out);
}

# scan all SDS files in the project
sub scan_sds {
		my $filename = $_;

		# check if the argument is an actual file
		return unless -f $filename;

		if ($filename =~ /^(.*)\.sds$/i) {
				my $sds_name = $1;
				my $sds_id = -1;

				open(my $fh_in, '<:encoding(UTF-8)', $filename) or die "Could not open file '$filename' $!";
				while ((my $line = <$fh_in>) && ($sds_id < 0)) {
						
						if ($line =~ /[<]SDSID[>]([0-9]*)[<][\/]SDSID[>]/g) {
								$sds_id = $1;
						}
				}

				close ($fh_in);

				return unless $sds_id >= 0;
				
				if (file_is_child_of ($filename, $oldgroupfolder)) {
						$sdsmap_grp->{$sds_id} = {
								'name' => $sds_name,
								'file' => File::Spec->catfile(getcwd(), $filename)
						};
				}

				$sdsmap_prj->{$sds_id} = {
						'name' => $sds_name,
						'file' => File::Spec->catfile(getcwd(), $filename)
				};
		}
}

sub scan_group_order {
		my $filename = $_;
		# check if the argument is an actual file
		return unless -f $filename;
		return unless ($filename =~ /.*\.sal$/i);

		# open the file and scan for GUID patterns
		open (my $fh, "<:encoding(UTF-8)", $filename) or die "Could not open file '$_' $!";
		while (my $line = <$fh>) {
				if ($line =~ /groupOrderId="([0-9]*)"/) {
						my $order = int($1);
						print "found group order $1 ($order) in $filename\n";
						$highest_group_order = $order if ($order > $highest_group_order);
						last;
				}
		}
		close ($fh);
}

sub scan_guid {
		my $filename = $_;
		# check if the argument is an actual file
		return unless -f $filename;
		return if ($filename =~ /.*\.bak$/i);
		return if ($filename =~ /.*\.sds$/i);
		
		my $file_has_guid = 0;
		
		# open the file and scan for GUID patterns
		open (my $fh, "<:encoding(UTF-8)", $filename) or die "Could not open file '$_' $!";
		while (my $line = <$fh>) {
				my @found_guids = ($line =~ /([[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12})/g);

				foreach my $found_guid (@found_guids) {
						store_guid ($found_guid);
						$file_has_guid = 1;
				}
		}
		close ($fh);

		if ($file_has_guid > 0) {
				my $filepath = File::Spec->canonpath(File::Spec->catfile(getcwd(), $filename));
				print "$filepath has GUID\n";
				push @guidfiles, $filepath;
		} else {
				push @nonguidfiles, $filepath;
		}
}

sub store_guid {
		my ($guid) = @_;

		if (! defined $guidmap->{$guid}) {
				$guidmap->{$guid} = {
				  'n' => 1,
				};
		} else {
				$guidmap->{$guid}->{'n'} += 1;
		}
}

sub file_is_child_of {
		my ($file, $parent) = (@_);
		
		my @dirs = File::Spec->splitdir(getcwd);
		my @parentdirs = File::Spec->splitdir($parent);

		return 0 if (scalar @dirs) < (scalar @parentdirs);

		while ((scalar @parentdirs) > 0) {
				my $dirc = shift(@dirs);
				my $parentc = shift(@parentdirs);
				
				return 0 unless ($dirc eq $parentc);
		}

		return 1;
}
