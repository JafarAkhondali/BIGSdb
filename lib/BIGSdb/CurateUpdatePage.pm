#Written by Keith Jolley
#Copyright (c) 2010, University of Oxford
#E-mail: keith.jolley@zoo.ox.ac.uk
#
#This file is part of Bacterial Isolate Genome Sequence Database (BIGSdb).
#
#BIGSdb is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#BIGSdb is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with BIGSdb.  If not, see <http://www.gnu.org/licenses/>.
package BIGSdb::CurateUpdatePage;
use strict;
use base qw(BIGSdb::CuratePage);
use List::MoreUtils qw(none);
use BIGSdb::Page qw(DATABANKS);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');

sub initiate {
	my ($self) = @_;
	foreach (qw (tooltips jQuery noCache)){
		$self->{$_} = 1;
	}
}

sub print_content {
	my ($self)      = @_;
	my $q           = $self->{'cgi'};
	my $table       = $q->param('table');
	my $record_name = $self->get_record_name($table);
	if ( !$self->{'datastore'}->is_table($table) ) {
		print "<div class=\"box\" id=\"statusbad\"><p>Table $table does not exist!</p></div>\n";
		return;
	}
	print "<h1>Update $record_name</h1>\n";
	if ( !$self->can_modify_table($table) ) {
		if ( $table eq 'sequences' && $q->param('locus') ) {
			my $locus = $q->param('locus');
			print
"<div class=\"box\" id=\"statusbad\"><p>Your user account is not allowed to update $locus sequences in the database.</p></div>\n";
		} else {
			print
			  "<div class=\"box\" id=\"statusbad\"><p>Your user account is not allowed to update this record.</p></div>\n";
		}
		return;
	} elsif ( ( $self->{'system'}->{'read_access'} eq 'acl' || $self->{'system'}->{'write_access'} eq 'acl' )
		&& $self->{'username'}
		&& !$self->is_admin
		&& $q->param('isolate_id')
		&& !$self->is_allowed_to_view_isolate( $q->param('isolate_id') ) )
	{
		print "<div class=\"box\" id=\"statusbad\"><p>Your user account is not allowed to modify data for this isolate.</p></div>\n";
		return;
	}
	if ( $table eq 'pending_allele_designations' ) {
		print "<div class=\"box\" id=\"statusbad\"><p>Pending designations cannot be updated using this function.</p></div>\n";
		return;
	} elsif ( $table eq 'allele_sequences' ) {
		print "<div class=\"box\" id=\"statusbad\"><p>Sequence tags cannot be updated using this function.</p></div>\n";
		return;
	}
	if ( ( $table eq 'scheme_fields' || $table eq 'scheme_members' ) && $self->{'system'}->{'dbtype'} eq 'sequences' && !$q->param('sent') )
	{
		print
		  "<div class=\"box\" id=\"warning\"><p>Please be aware that any modifications to the structure of this scheme will result in the
		removal of all data from it. This is done to ensure data integrity.  This does not affect allele designations, but any profiles
		will have to be reloaded.</p></div>\n";
	}
	my $attributes = $self->{'datastore'}->get_table_field_attributes($table);
	my @query_values;
	foreach (@$attributes) {
		my $value = $q->param( $_->{'name'} );
		$value =~ s/'/\\'/g;
		if ( $_->{'primary_key'} eq 'yes' ) {
			push @query_values, "$_->{name} = '$value'";
		}
	}
	if ( !@query_values ) {
		print "<div class=\"box\" id=\"statusbad\"><p>No identifying attributes sent.</p>\n";
		return;
	}
	$" = ' AND ';
	my $qry = "SELECT * FROM $table WHERE @query_values";
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute(); };
	if ($@) {
		$logger->error("Can't execute: $qry");
		print "<div class=\"box\" id=\"statusbad\"><p>No identifying attributes sent.</p>\n";
		return;
	} else {
		$logger->debug("Query: $qry");
	}
	my $data = $sql->fetchrow_hashref();
	if ( $table eq 'sequences' ) {
		my $sql = $self->{'db'}->prepare("SELECT field,value FROM sequence_extended_attributes WHERE locus=? AND allele_id=?");
		eval { $sql->execute( $data->{'locus'}, $data->{'allele_id'} ); };
		if ($@) {
			$logger->error("Can't execute $@");
		}
		while ( my ( $field, $value ) = $sql->fetchrow_array ) {
			$data->{$field} = $value;
		}
	}
	my $buffer = $self->create_record_table( $table, $data, 1 );
	my %newdata;
	foreach (@$attributes) {
		if ( $q->param( $_->{'name'} ) ne '' ) {
			$newdata{ $_->{'name'} } = $q->param( $_->{'name'} );
		}
	}
	$newdata{'datestamp'}    = $self->get_datestamp;
	$newdata{'curator'}      = $self->get_curator_id();
	$newdata{'date_entered'} = $data->{'date_entered'};
	my @problems;
	my @extra_inserts;
	if ( $q->param('sent') ) {
		@problems = $self->check_record( $table, \%newdata, 1, $data );
		if (@problems) {
			$" = "<br />\n";
			print "<div class=\"box\" id=\"statusbad\"><p>@problems</p></div>\n";
		} else {
			if (   $table eq 'users'
				&& $newdata{'id'} == $self->get_curator_id()
				&& $newdata{'status'} eq 'user' )
			{
				print <<"HTML";
<div class="box" id="statusbad"><p>It's not a good idea to remove curator status from yourself 
as you will lock yourself out!  If you really wish to do this, you'll need to do 
it from another curator account.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
				return;
			} elsif ( $table eq 'users'
				&& $self->is_admin()
				&& $newdata{'id'} == $self->get_curator_id()
				&& $newdata{'status'} ne 'admin' )
			{
				print <<"HTML";
<div class="box" id="statusbad"><p>It's not a good idea to remove admin status from yourself 
as you will lock yourself out!  If you really wish to do this, you'll need to do 
it from another admin account.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
				return;
			}    #special case to check that only one primary key field is set for a scheme field
			elsif ( $table eq 'scheme_fields' && $newdata{'primary_key'} eq 'true' ) {
				my $primary_key;
				eval {
					$primary_key =
					  $self->{'datastore'}
					  ->run_simple_query( "SELECT field FROM scheme_fields WHERE primary_key AND scheme_id=?", $newdata{'scheme_id'} )->[0];
				};
				$logger->error($@) if $@;
				if ( $primary_key && $primary_key ne $newdata{'field'} ) {
					print <<"HTML";
<div class="box" id="statusbad"><p>This scheme already has a primary key field set ($primary_key).</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
					return;
				}
			} elsif ( $table eq 'sequences' ) {

				#check extended attributes if they exist
				my $sql =
				  $self->{'db'}->prepare("SELECT field,required,value_format,value_regex FROM locus_extended_attributes WHERE locus=?");
				eval { $sql->execute( $newdata{'locus'} ); };
				if ($@) {
					$logger->error("Can't execute $@");
				}
				my @missing_field;
				while ( my ( $field, $required, $format, $regex ) = $sql->fetchrow_array ) {
					$newdata{$field} = $q->param($field);
					if ( $required && $newdata{$field} eq '' ) {
						push @missing_field, $field;
					} elsif ( $format eq 'integer' && $newdata{$field} ne '' && !BIGSdb::Utils::is_int( $newdata{$field} ) ) {
						print <<"HTML";
<div class="box" id="statusbad"><p>$field must be an integer.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
						return;
					} elsif ( $newdata{$field} ne '' && $regex && $newdata{$field} !~ /$regex/ ) {
						print <<"HTML";
<div class="box" id="statusbad"><p>Field '$field' does not conform to specified format.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
						return;
					} else {
						( my $cleaned_field = $field )            =~ s/'/\\'/g;
						( my $cleaned_locus = $newdata{'locus'} ) =~ s/'/\\'/g;
						( my $cleaned_value = $newdata{$field} )  =~ s/'/\\'/g;
						my $insert;
						if ( $cleaned_value ne '' ) {
							if (
								$self->{'datastore'}->run_simple_query(
									"SELECT COUNT(*) FROM sequence_extended_attributes WHERE locus=? AND field=? AND allele_id=?",
									$newdata{'locus'}, $field, $newdata{'allele_id'} )->[0]
							  )
							{
								$insert =
"UPDATE sequence_extended_attributes SET value='$cleaned_value',datestamp='now',curator=$newdata{'curator'} WHERE locus='$cleaned_locus' AND field='$cleaned_field' AND allele_id='$newdata{'allele_id'}'";
							} else {
								$insert =
"INSERT INTO sequence_extended_attributes(locus,field,allele_id,value,datestamp,curator) VALUES ('$cleaned_locus','$cleaned_field','$newdata{'allele_id'}','$cleaned_value','now',$newdata{'curator'})";
							}
							push @extra_inserts, $insert;
						}
					}
				}
				if (@missing_field) {
					$" = ', ';
					print <<"HTML";
<div class="box" id="statusbad"><p>Please fill in all extended attribute fields.  The following extended attribute fields are missing: @missing_field.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
					return;
				}
				( my $cleaned_locus = $newdata{'locus'} ) =~ s/'/\\'/g;
				my $existing_pubmeds =
				  $self->{'datastore'}->run_list_query( "SELECT pubmed_id FROM sequence_refs WHERE locus=? AND allele_id=?",
					$newdata{'locus'}, $newdata{'allele_id'} );
				my @new_pubmeds = split /\r?\n/, $q->param('pubmed');
				foreach my $new (@new_pubmeds) {
					chomp $new;
					next if $new eq '';
					if ( !@$existing_pubmeds || none { $new eq $_ } @$existing_pubmeds ) {
						if ( !BIGSdb::Utils::is_int($new) ) {
							print <<"HTML";
<div class="box" id="statusbad"><p>PubMed ids must be integers.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
							return;
						}
						push @extra_inserts,
"INSERT INTO sequence_refs (locus,allele_id,pubmed_id,curator,datestamp) VALUES ('$cleaned_locus','$newdata{'allele_id'}',$new,$newdata{'curator'},'today')";
					}
				}
				foreach my $existing (@$existing_pubmeds) {
					if ( !@new_pubmeds || none { $existing eq $_ } @new_pubmeds ) {
						push @extra_inserts,
"DELETE FROM sequence_refs WHERE locus='$cleaned_locus' AND allele_id='$newdata{'allele_id'}' AND pubmed_id='$existing'";
					}
				}
				my @databanks = DATABANKS;
				foreach my $databank (@databanks) {
					my $existing_accessions =
					  $self->{'datastore'}
					  ->run_list_query( "SELECT databank_id FROM accession WHERE locus=? AND allele_id=? AND databank=?",
						$newdata{'locus'}, $newdata{'allele_id'}, $databank );
					my @new_accessions = split /\r?\n/, $q->param("databank_$databank");
					foreach my $new (@new_accessions) {
						chomp $new;
						next if $new eq '';
						(my $clean_new = $new) =~ s/'/\\'/g;
						if ( !@$existing_accessions || none { $clean_new eq $_ } @$existing_accessions ) {
							
							push @extra_inserts,
"INSERT INTO accession (locus,allele_id,databank,databank_id,curator,datestamp) VALUES ('$cleaned_locus','$newdata{'allele_id'}','$databank','$clean_new',$newdata{'curator'},'today')";
						}
					}
					foreach my $existing (@$existing_accessions) {
						(my $clean_existing = $existing) =~ s/'/\\'/g;
						if ( !@new_accessions || none { $clean_existing eq $_ } @new_accessions ) {
							push @extra_inserts,
"DELETE FROM accession WHERE locus='$cleaned_locus' AND allele_id='$newdata{'allele_id'}' AND databank='$databank' AND databank_id='$clean_existing'";
						}
					}
				}
			} elsif ($table eq 'locus_descriptions'){
				( my $cleaned_locus = $newdata{'locus'} ) =~ s/'/\\'/g;
				my $existing_aliases =
				  $self->{'datastore'}->run_list_query( "SELECT alias FROM locus_aliases WHERE locus=?",
					$newdata{'locus'} );
				my @new_aliases = split /\r?\n/, $q->param('aliases');
				foreach my $new (@new_aliases) {
					chomp $new;
					next if $new eq '';
					if ( !@$existing_aliases || none { $new eq $_ } @$existing_aliases ) {
							push @extra_inserts,
"INSERT INTO locus_aliases (locus,alias,curator,datestamp) VALUES ('$cleaned_locus','$new',$newdata{'curator'},'today')";
					}
				}
				foreach my $existing (@$existing_aliases) {
					if ( !@new_aliases || none { $existing eq $_ } @new_aliases ) {
							push @extra_inserts,
"DELETE FROM locus_aliases WHERE locus='$cleaned_locus' AND alias='$existing'";
					}
				}
				my $existing_pubmeds =
				  $self->{'datastore'}->run_list_query( "SELECT pubmed_id FROM locus_refs WHERE locus=?",
					$newdata{'locus'} );
				$"=';';
				my @new_pubmeds = split /\r?\n/, $q->param('pubmed');
				foreach my $new (@new_pubmeds) {
					chomp $new;
					next if $new eq '';
					if ( !@$existing_pubmeds || none { $new eq $_ } @$existing_pubmeds ) {
						if ( !BIGSdb::Utils::is_int($new) ) {
							print <<"HTML";
<div class="box" id="statusbad"><p>PubMed ids must be integers.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
							return;
						}
						push @extra_inserts,
"INSERT INTO locus_refs (locus,pubmed_id,curator,datestamp) VALUES ('$cleaned_locus',$new,$newdata{'curator'},'today')";
					}
				}
				foreach my $existing (@$existing_pubmeds) {
					if ( !@new_pubmeds || none { $existing eq $_ } @new_pubmeds ) {
							push @extra_inserts,
"DELETE FROM locus_refs WHERE locus='$cleaned_locus' AND pubmed_id='$existing'";
					}
				}
				my @new_links;
				my $i=1;
				foreach (split/\r?\n/,$q->param('links')){
					next if $_ eq '';
					push @new_links,"$i|$_";
					$i++;
				}
				my @existing_links;
				my $sql = $self->{'db'}->prepare("SELECT link_order,url,description FROM locus_links WHERE locus=? ORDER BY link_order");
				eval {
					$sql->execute($q->param('locus'));
				};
				if ($@){
					$logger->error("Can't execute $@");
				}
				while (my ($order,$url,$desc) = $sql->fetchrow_array){
					push @existing_links,"$order|$url|$desc";
				}
				foreach my $existing (@existing_links) {
					if ( !@new_links || none { $existing eq $_ } @new_links ) {
						if ($existing =~ /^\d+\|(.+?)\|.+$/){
							my $url = $1;
							$url =~ s/'/\\'/g;
								push @extra_inserts,
"DELETE FROM locus_links WHERE locus='$cleaned_locus' AND url='$url'";
						}
					}
				}
				
				foreach my $new (@new_links){	
					chomp $new;
					next if $new eq '';	
					if ( !@existing_links || none { $new eq $_ } @existing_links ) {	
						if ($new !~ /^(.+?)\|(.+)\|(.+)$/){
							print <<"HTML";
	<div class="box" id="statusbad"><p>Links must have an associated description separated from the URL by a '|'.</p>
	<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
							return;
						} else {
							my ($field_order,$url,$desc) = ($1,$2,$3);
							$url =~ s/'/\\'/g;
							$desc =~ s/'/\\'/g;
							push @extra_inserts,"INSERT INTO locus_links (locus,url,description,link_order,curator,datestamp) VALUES ('$cleaned_locus','$url','$desc',$field_order,$newdata{'curator'},'today')";
						}						
					}
				}
			}    #special case to check that changing a locus allele_id_format to integer is allowed with currently existing data
			elsif ( $table eq 'loci' && $self->{'system'}->{'dbtype'} eq 'sequences' ) {
				my $non_int;
				if ( $newdata{'allele_id_format'} eq 'integer' ) {
					my $ids = $self->{'datastore'}->run_list_query( "SELECT allele_id FROM sequences WHERE locus=?", $newdata{'id'} );
					foreach (@$ids) {
						if ( !BIGSdb::Utils::is_int($_) ) {
							$non_int = 1;
							last;
						}
					}
				}
				if ($non_int) {
					print <<"HTML";
<div class="box" id="statusbad"><p>The sequence table already contains data with non-integer allele ids.  You will need to remove
these before you can change the allele_id_format to 'integer'.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
					return;

					#special case to ensure that a locus length is set if it is not marked as variable length
				} elsif ( $newdata{'length_varies'} ne 'true' && !$newdata{'length'} ) {
					print <<"HTML";
<div class="box" id="statusbad"><p>Locus set as non variable length but no length is set.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
					return;
				}

				#special case to check that start_pos is less than end_pos for allele_sequence
			} elsif ( $table eq 'allele_sequences' && $newdata{'end_pos'} < $newdata{'start_pos'} ) {
				print <<"HTML";
<div class="box" id="statusbad"><p>Sequence end position must be greater than the start position - set reverse = 'true' if sequence is reverse complemented.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
				return;
			} elsif ( ( $table eq 'allele_designations' || $table eq 'sequence_bin' )
				&& !$self->is_allowed_to_view_isolate( $newdata{'isolate_id'} ) )
			{
				my $record_type = $self->get_record_name($table);
				print <<"HTML";
<div class="box" id="statusbad"><p>Your user account is not allowed to update $record_type for isolate $newdata{'isolate_id'}.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
				return;
			} elsif ( $self->{'system'}->{'read_access'} eq 'acl'
				&& $self->{'username'}
				&& !$self->is_admin
				&& ( $table eq 'accession' || $table eq 'allele_sequences' )
				&& $self->{'system'}->{'dbtype'} eq 'isolates' )
			{
				my $isolate_id_ref =
				  $self->{'datastore'}->run_simple_query( "SELECT isolate_id FROM sequence_bin WHERE id=?", $newdata{'seqbin_id'} );
				if ( ref $isolate_id_ref eq 'ARRAY' && !$self->is_allowed_to_view_isolate( $isolate_id_ref->[0] ) ) {
					my $record_type = $self->get_record_name($table);
					print <<"HTML";
<div class="box" id="statusbad"><p>The $record_type you are trying to update belongs to an isolate to which your user account
is not allowed to access.</p>
<p><a href="$self->{'script_name'}?db=$self->{'instance'}">Back to main page</a></p></div>
HTML
					return;
				}
			}
			my (@values);
			my %new_value;
			foreach (@$attributes) {
				next if $_->{'user_update'} eq 'no';
				$newdata{ $_->{'name'} } =~ s/\\/\\\\/g;
				$newdata{ $_->{'name'} } =~ s/'/\\'/g;
				if ( $_->{'name'} =~ /sequence$/ ) {
					$newdata{ $_->{'name'} } = uc( $newdata{ $_->{'name'} } );
					$newdata{ $_->{'name'} } =~ s/\s//g;
				}
				if ( $newdata{ $_->{'name'} } ne '' ) {
					push @values, "$_->{'name'} = '$newdata{ $_->{'name'}}'";
					$new_value{ $_->{'name'} } = $newdata{ $_->{'name'} };
				} else {
					push @values, "$_->{'name'} = null";
				}
			}
			$" = ',';
			my $qry = "UPDATE $table SET @values WHERE ";
			$" = ' AND ';
			$qry .= "@query_values";
			eval {
				$self->{'db'}->do($qry);
				foreach (@extra_inserts) {
					$self->{'db'}->do($_);					
				}
				if ( ( $table eq 'scheme_members' || $table eq 'scheme_fields' ) && $self->{'system'}->{'dbtype'} eq 'sequences' ) {
					$self->remove_profile_data( $data->{'scheme_id'} );
					$self->drop_scheme_view( $data->{'scheme_id'} );
					$self->create_scheme_view( $data->{'scheme_id'} );
				}
			};
			if ($@) {
				print "<div class=\"box\" id=\"statusbad\"><p>Update failed - transaction cancelled - no records have been touched.</p>\n";
				if ( $@ =~ /duplicate/ && $@ =~ /unique/ ) {
					print
"<p>Data entry would have resulted in records with either duplicate ids or another unique field with duplicate values.</p></div>\n";
				} else {
					print "<p>Error message: $@</p></div>\n";
				}
				$self->{'db'}->rollback();
			} else {
				$self->{'db'}->commit()
				  && print "<div class=\"box\" id=\"resultsheader\"><p>$record_name updated!</p>";
				print "<p><a href=\""
				  . $q->script_name
				  . "?db=$self->{'instance'}&amp;page=tableQuery&amp;table=$table\">Update another</a> | <a href=\""
				  . $q->script_name
				  . "?db=$self->{'instance'}\">Back to main page</a></p></div>\n";
				if ( $table eq 'allele_designations' ) {
					$self->update_history( $data->{'isolate_id'}, "$data->{'locus'}: $data->{'allele_id'} -> $new_value{'allele_id'}" );
				}
				return;
			}
		}
	}
	print $buffer;
}

sub get_title {
	my ($self) = @_;
	my $desc  = $self->{'system'}->{'description'} || 'BIGSdb';
	my $table = $self->{'cgi'}->param('table');
	my $type  = $self->get_record_name($table);
	return "Update $type - $desc";
}
1;
