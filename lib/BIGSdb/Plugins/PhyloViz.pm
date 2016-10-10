#PhyloViz.pm - phylogenetic inference and data visualization for sequence based typing methods for BIGSdb
#Written by Emmanuel Quevillon
#Copyright (c) 2016, Institut Pasteur, Paris
#E-mail: tuco@pasteur.fr
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
#
#Modifications to initial code made by Keith Jolley.
#https://github.com/kjolley/BIGSdb/commits/develop/lib/BIGSdb/Plugins/PhyloViz.pm
package BIGSdb::Plugins::PhyloViz;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::Plugin);
use List::MoreUtils qw(uniq);
use BIGSdb::Constants qw(GOOD BAD);
use LWP::UserAgent;
use JSON;
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Plugins');
use constant WEB_ROOT => 'http://online.phyloviz.net';

sub get_attributes {
	my ($self) = @_;
	my %att = (
		name        => 'PhyloViz',
		author      => 'Emmanuel Quevillon',
		affiliation => 'Institut Pasteur, Paris',
		email       => 'tuco@pasteur.fr',
		description => 'Creates phylogenetic inference and data visualization for sequence based typing methods',
		category    => 'Analysis',
		buttontext  => 'PhyloViz',
		menutext    => 'PhyloViz',
		module      => 'PhyloViz',
		version     => '1.0.0',
		dbtype      => 'isolates',
		section     => 'analysis,postquery',
		input       => 'query',
		system_flag => 'PhyloViz',
		requires    => 'js_tree',
		help        => 'tooltips',
		order       => 33,
		min         => 2,
		max         => 5000
	);
	return \%att;
}

sub run {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	say q(<h1>PhyloViz: phylogenetic tree vizualisation</h1>);
	my $isolate_ids = [];
	if ( $q->param('submit') ) {
		my @list = split /[\r\n]+/x, $q->param('list');
		@list = uniq @list;
		if ( !@list ) {
			my $qry = "SELECT id FROM $self->{'system'}->{'view'} ORDER BY id";
			my $id_list = $self->{'datastore'}->run_query( $qry, undef, { fetch => 'col_arrayref' } );
			@list = @$id_list;
		}
		( $isolate_ids, my $invalid ) = $self->check_id_list( \@list );
		my ( @error, @info );
		if ( !@$isolate_ids || @$isolate_ids < 2 ) {
			push @error, q(You must select at least two valid isolate ids.);
		}
		if (@$invalid) {
			local $" = q(, );
			push @info,
			  qq(The id list contained some invalid values - these will be ignored. Invalid values: @$invalid.);
		}
		my $max = $self->get_attributes->{'max'};
		if ( @$isolate_ids > $max ) {
			my $count = BIGSdb::Utils::commify( scalar @$isolate_ids );
			push @error, qq(This analysis is limited to $max isolates. You have selected $count.);
		}

		# Get the selected isolates field(s)
		####################################
		my $isolates_fields          = $self->{'xmlHandler'}->get_field_list;
		my $selected_isolates_fields = [];
		my $selected_extended_fields = {};
		foreach my $field (@$isolates_fields) {
			if ( $q->param("f_$field") ) {
				push @$selected_isolates_fields, $field;
			}
		}
		my $ext_att = $self->get_extended_attributes;
		foreach my $field ( keys %$ext_att ) {
			foreach my $ext_field ( @{ $ext_att->{$field} } ) {
				if ( $q->param("f_${field}___$ext_field") ) {
					push @{ $selected_extended_fields->{$field} }, $ext_field;
				}
			}
		}
		if ( !@$selected_isolates_fields ) {
			push @error, q(You must at least select <strong>one isolate field!</strong>);
		}
		my $selected_loci = $self->get_selected_loci;
		my ( $pasted_cleaned_loci, $invalid_loci ) = $self->get_loci_from_pasted_list( { dont_clear => 1 } );
		push @$selected_loci, @$pasted_cleaned_loci;
		@$selected_loci = uniq @$selected_loci;
		if (@$invalid_loci) {
			local $" = ', ';
			push @info, q(The locus list contained some invalid values - )
			  . qq(these will be ignored. Invalid values: @$invalid_loci.);
		}
		my $scheme_ids = $self->_get_selected_schemes;
		$self->add_scheme_loci($selected_loci);
		if ( !@$selected_loci ) {
			push @error, q(You must select at least <strong>one locus!</strong>);
		}
		if ( @error || @info ) {
			say q(<div class="box" id="statusbad">);
			foreach my $msg ( @error, @info ) {
				say qq(<p>$msg</p>);
			}
			say q(</div>);
			if (@error) {
				$self->_print_interface($isolate_ids);
				return;
			}
		}

		# From here, with parameters retrieved, we need to build the 2 files needed for PhyloViz:
		# - Profile data
		# - Auxiliary data
		local $| = 1;
		say q(<div class="box" id="resultstable">);
		say q(<p>Please wait for processing to finish (do not refresh page).</p>);
		say q(<p class="hideonload"><span class="main_icon fa fa-refresh fa-spin fa-4x"></span></p>);
		say q(<p>Data are being processed and sent to PhyloViz Online.</p>);
		my $uuid           = BIGSdb::Utils::get_random();
		my $profile_file   = "$self->{'config'}->{'secure_tmp_dir'}/${uuid}_profile_data.txt";
		my $auxiliary_file = "$self->{'config'}->{'secure_tmp_dir'}/${uuid}_auxiliary_data.txt";

		if (
			$self->_generate_profile_file(
				{ file => $profile_file, isolates => $isolate_ids, loci => $selected_loci }
			)
		  )
		{
			say q(</div><div class="box" id="statusbad"><p>Nothing found )
			  . q(in the database for your isolates!</p></div>);
			return;
		}
		$self->_generate_auxiliary_file(
			{
				file            => $auxiliary_file,
				isolates        => $isolate_ids,
				fields          => $selected_isolates_fields,
				extended_fields => $selected_extended_fields,
				schemes         => $scheme_ids
			}
		);
		my ( $phylo_id, $msg ) =
		  $self->_upload_data_to_phyloviz(
			{ profile => $profile_file, auxiliary => $auxiliary_file, count => scalar @$isolate_ids } );
		if ( !$phylo_id ) {
			say qq(</div><div class="box" id="statusbad"><p>Something went wrong: $msg</p></div>);
			return;
		}
		say qq(<p>Click this <a href="$phylo_id" target="_blank">link</a> to view your tree</p>);
		say q(</div>);
		unlink $profile_file, $auxiliary_file;
		return;
	}
	if ( $q->param('query_file') ) {
		my $qry_ref = $self->get_query( $q->param('query_file') );
		if ($qry_ref) {
			$isolate_ids = $self->get_ids_from_query($qry_ref);
		}
	}
	$self->_print_interface($isolate_ids);
	return;
}

sub _get_selected_schemes {
	my ($self) = @_;
	my $q      = $self->{'cgi'};
	my $set_id = $self->get_set_id;
	my $schemes = $self->{'datastore'}->get_scheme_list( { set_id => $set_id, with_pk => 1 } );
	my @scheme_ids;
	foreach my $scheme (@$schemes) {
		push @scheme_ids, $scheme->{'id'} if $q->param("s_$scheme->{'id'}");
	}
	@scheme_ids = sort { $a <=> $b } @scheme_ids;
	return \@scheme_ids;
}

sub _print_interface {
	my ( $self, $isolate_ids ) = @_;
	my $q = $self->{'cgi'};
	say q(<div class="box" id="queryform"><p>PhyloViz: This plugin allows the analysis of sequence-based )
	  . q(typing methods that generate allelic profiles and their associated epidemiological data.</p>);
	say $q->start_form;
	$self->print_id_fieldset( { list => $isolate_ids } );
	$self->print_isolates_fieldset( 1, { extended_attributes => 1 } );
	$self->print_isolates_locus_fieldset( { locus_paste_list => 1 } );
	$self->print_scheme_fieldset( { fields_or_loci => 0 } );
	$self->print_action_fieldset( { no_reset => 1 } );
	say $q->hidden($_) foreach qw (db page name query_file scheme_id set_id list_file datatype);
	say $q->end_form();
	say q(</div>);
	return;
}

sub _upload_data_to_phyloviz {
	my ( $self, $args ) = @_;
	$self->{'mod_perl_request'}->rflush() if $ENV{'MOD_PERL'};
	say q(<p>Sending data to PhyloViz online ... );
	my $uuid = 0;
	my $msg  = 'No message';
	my ($data_set) = ( $args->{'profile'} =~ /.+\/([^\/]+)\.txt/x );
	my $user       = $self->{'config'}->{'phyloviz_user'};
	my $pass       = $self->{'config'}->{'phyloviz_passwd'};
	if ( !$user || !$pass ) {
		say BAD . q(</p>);
		return ( 0, 'Missing PhyloViz connection parameters!' );
	}
	my $desc = "$self->{'system'}->{'description'} $args->{'count'} isolates";
	$desc =~ s/\W/_/gx;
	my $uploader       = LWP::UserAgent->new( cookie_jar => {}, agent => 'BIGSdb' );
	my $login_url      = WEB_ROOT . '/users/api/login';
	my $login_response = $uploader->post( $login_url, { username => $user, password => $pass } );
	if ( !$login_response->is_success ) {
		say BAD . q(</p>);
		if ( $login_response->status_line =~ /Unauthorized/x ) {
			$logger->error('PhyloViz: Invalid username/password');
			return ( 0, 'PhyloViz site rejected username/password' );
		}
		$logger->error( $login_response->status_line );
		return ( 0, $login_response->status_line );
	}
	my $json = $login_response->decoded_content;
	if ( decode_json($json)->{'name'} eq $user ) {
		$logger->info("Logged in to PhyloViz Online as $user");
	} else {
		say BAD . q(</p>);
		$logger->error('PhyloViz: Not logged in');
		return ( 0, 'Could not log in to PhyloViz' );
	}
	my $upload_url      = WEB_ROOT . '/api/db/postgres/upload';
	my $upload_response = $uploader->post(
		$upload_url,
		Content_Type => 'form-data',
		Content      => [
			datasetName         => $data_set,
			dataset_description => $desc,
			makePublic          => 'true',
			numberOfFiles       => 2,
			fileProfile         => [ $args->{'profile'} ],
			fileMetadata        => [ $args->{'auxiliary'} ]
		]
	);
	if ( !$upload_response->is_success ) {
		say BAD . q(</p>);
		$logger->error( $upload_response->status_line );
		return ( 0, 'Dataset could not be uploaded' );
	}
	$json = $upload_response->decoded_content;
	my $dataset_id   = decode_json($json)->{'datasetID'};
	my $run_url      = WEB_ROOT . "/api/algorithms/goeBURST?dataset_id=$dataset_id&save=true";
	my $run_response = $uploader->get($run_url);
	if ( $run_response->is_success ) {
		say GOOD . q(</p>);
		return WEB_ROOT . "/main/dataset/$dataset_id";
	} else {
		say BAD . q(</p>);
		$logger->error( $run_response->status_line );
		return ( 0, 'Could not run goeBURST' );
	}
	return;
}

sub _generate_profile_file {
	my ( $self, $args ) = @_;
	my ( $filename, $isolates, $loci ) = @{$args}{qw(file isolates loci)};
	print q(<p>Generating profile data file ... );
	if ( $ENV{'MOD_PERL'} ) {
		$self->{'mod_perl_request'}->rflush;
		return 1 if $self->{'mod_perl_request'}->connection->aborted;
	}
	if (@$isolates) {
		open( my $fh, '>:encoding(utf8)', $filename )
		  or $logger->error("Can't open temp file $filename for writing");
		local $" = qq(\t);
		say $fh qq(id\t@$loci);
		foreach my $isolate_id (@$isolates) {
			my @profile;
			push @profile, $isolate_id;
			my $ad = $self->{'datastore'}->get_all_allele_designations($isolate_id);
			foreach my $locus (@$loci) {
				my @values = sort keys %{ $ad->{$locus} };

				#Just pick lowest value
				push @profile, $values[0] // q();
			}
			say $fh qq(@profile);
		}
		close $fh;
	} else {
		return 1;
	}
	say GOOD . q(</p>);
	return 0;
}

sub _generate_auxiliary_file {
	my ( $self, $args ) = @_;
	my ( $filename, $isolates, $fields, $ext_fields, $schemes ) =
	  @{$args}{qw(file isolates fields extended_fields schemes)};

	# We ensure 'id' is in the list
	unshift @$fields, 'id';

	# And we rearrange by removing the one already there if it was.
	@$fields = uniq @$fields;
	print q(<p>Generating auxiliary file ... );
	if ( $ENV{'MOD_PERL'} ) {
		$self->{'mod_perl_request'}->rflush;
		return 1 if $self->{'mod_perl_request'}->connection->aborted;
	}
	local $" = q(,);
	my $query = "SELECT @$fields FROM isolates WHERE id IN (@$isolates) ORDER BY id;";
	open( my $fh, '>:encoding(utf8)', $filename )
	  or $logger->error("Can't open temp file $filename for writing");
	my $data = $self->{'datastore'}->run_query( $query, undef, { fetch => 'all_arrayref', slice => {} } );
	my $extended_attributes =
	  $self->{'datastore'}
	  ->run_query( 'SELECT * FROM isolate_value_extended_attributes', undef, { fetch => 'all_arrayref', slice => {} } );
	my $extended_values = {};
	foreach my $ext_data (@$extended_attributes) {
		$extended_values->{ $ext_data->{'isolate_field'} }->{ $ext_data->{'attribute'} }
		  ->{ $ext_data->{'field_value'} } = $ext_data->{'value'};
	}
	my @header;
	foreach my $field (@$fields) {
		push @header, $field;
		if ( $ext_fields->{$field} ) {
			foreach my $ext_field ( @{ $ext_fields->{$field} } ) {
				push @header, $ext_field;
			}
		}
	}
	my $set_id        = $self->get_set_id;
	my $scheme_fields = {};
	foreach my $scheme_id (@$schemes) {
		my $name = $self->{'datastore'}->get_scheme_info($scheme_id)->{'name'};
		$scheme_fields->{$scheme_id} = $self->{'datastore'}->get_scheme_fields($scheme_id);
		foreach my $field ( @{ $scheme_fields->{$scheme_id} } ) {
			push @header, "$field ($name)";
		}
	}
	local $" = qq(\t);
	say $fh qq(@header);
	no warnings 'uninitialized';
	foreach my $isolate_data (@$data) {
		my @values;
		foreach my $field (@$fields) {
			push @values, $isolate_data->{ lc $field };
			if ( $ext_fields->{$field} ) {
				foreach my $ext_field ( @{ $ext_fields->{$field} } ) {
					push @values, $extended_values->{$field}->{$ext_field}->{ $isolate_data->{ lc $field } };
				}
			}
		}
		foreach my $scheme_id (@$schemes) {
			my $scheme_values =
			  $self->{'datastore'}->get_scheme_field_values_by_isolate_id( $isolate_data->{'id'}, $scheme_id );
			foreach my $field ( @{ $scheme_fields->{$scheme_id} } ) {
				my @field_values = keys %{ $scheme_values->{ lc $field } };
				local $" = q(,);
				push @values, qq(@field_values);
			}
		}
		say $fh qq(@values);
	}
	close $fh;
	say GOOD . q(</p>);
	return 0;
}
1;
