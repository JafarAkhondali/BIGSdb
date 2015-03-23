#Written by Keith Jolley
#Copyright (c) 2015, University of Oxford
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
package BIGSdb::REST::Routes::OAuth;
use strict;
use warnings;
use 5.010;
use Net::OAuth;
$Net::OAuth::PROTOCOL_VERSION = Net::OAuth::PROTOCOL_VERSION_1_0A;
use Dancer2 appname                => 'BIGSdb::REST::Interface';
use constant REQUEST_TOKEN_EXPIRES => 3600;
use constant REQUEST_TOKEN_TIMEOUT => 600;

#get_request_token
any [qw(get post)] => '/db/:db/oauth/get_request_token' => sub {
	my $self   = setting('self');
	my $params = params;
	my $db     = param('db');
	my $consumer_secret =
	  $self->{'datastore'}
	  ->run_query( "SELECT client_secret FROM clients WHERE client_id=?", param('oauth_consumer_key'), { db => $self->{'auth_db'} } );
	if ( !$consumer_secret ) {
		send_error( "Unrecognized client", 403 );
	}
	my $request_params = {};
	$request_params->{$_} = param($_) foreach qw(
	  oauth_callback
	  oauth_consumer_key
	  oauth_signature
	  oauth_signature_method
	  oauth_nonce
	  oauth_timestamp
	  oauth_version
	);
	my $request = eval {
		Net::OAuth->request('request token')->from_hash(
			$request_params,
			request_method  => request->method,
			request_url     => uri_for("/db/$db/oauth/get_request_token")->as_string,
			consumer_secret => $consumer_secret
		);
	};

	if ($@) {
		warn $@;
		if ( $@ =~ /Missing required parameter \'(\w+?)\'/ ) {
			send_error( "Invalid token request. Missing required parameter: $1", 400 );
		} else {
			$self->{'logger'}->error($@);
			send_error( "Invalid token request", 400 );
		}
	}
	$self->{'logger'}->debug( "Request string: " . $request->signature_base_string );
	if ( !$request->verify ) {
		send_error( "Signature verification failed", 401 );
	}
	if ( abs( $request->timestamp - time ) > REQUEST_TOKEN_TIMEOUT ) {
		send_error( "Request timestamp more than " . REQUEST_TOKEN_TIMEOUT . " seconds from current time.", 401 );
	}
	my $request_repeated = $self->{'datastore'}->run_query(
		"SELECT EXISTS(SELECT * FROM request_tokens WHERE (nonce,timestamp)=(?,?))",
		[ param('oauth_nonce'), param('oauth_timestamp') ],
		{ db => $self->{'auth_db'} }
	);
	if ($request_repeated) {
		send_error( "Request with same nonce and timestamp already made", 401 );
	}
	my $token        = BIGSdb::Utils::random_string(32);
	my $token_secret = BIGSdb::Utils::random_string(32);
	eval {
		$self->{'auth_db'}->do( "DELETE FROM request_tokens WHERE start_time<?", undef, time - REQUEST_TOKEN_EXPIRES );
		$self->{'auth_db'}->do(
			"INSERT INTO request_tokens (token,secret,client_id,nonce,timestamp,start_time) VALUES (?,?,?,?,?,?)",
			undef, $token, $token_secret, param('oauth_consumer_key'),
			param('oauth_nonce'), param('oauth_timestamp'), time
		);
	};
	if ($@) {
		$self->{'logger'}->error($@);
		$self->{'auth_db'}->rollback;
		send_error( "Error creating request token", 400 );
	}
	$self->{'auth_db'}->commit;
	return { oauth_token => $token, oauth_token_secret => $token_secret, oauth_callback_confirmed => 'true' };
};

#get_access_token
any [qw(get post)] => '/db/:db/oauth/get_access_token' => sub {
	my $self   = setting('self');
	my $params = params;
	my $db     = param('db');
	my $consumer_secret =
	  $self->{'datastore'}
	  ->run_query( "SELECT client_secret FROM clients WHERE client_id=?", param('oauth_consumer_key'), { db => $self->{'auth_db'} } );
	if ( !$consumer_secret ) {
		send_error( "Unrecognized client", 403 );
	}
	my $request_token = $self->{'datastore'}->run_query( "SELECT * FROM request_tokens WHERE token=?",
		param('oauth_token'), { fetch => 'row_hashref', db => $self->{'auth_db'} } );
	if ( !$request_token->{'secret'} ) {
		send_error( "Invalid request token.  Generate new request token (/get_request_token).", 401 );
	} elsif ( !$request_token->{'verifier'} || $request_token->{'verifier'} ne param('oauth_verifier') ) {
		send_error( "Invalid verifier code.", 401 );
	} elsif ( $request_token->{'redeemed'} ) {
		send_error( "Request token has already been redeemed.  Generate new request token (/get_request_token).", 401 );
	} elsif ( abs( $request_token->{'timestamp'} - time ) > REQUEST_TOKEN_EXPIRES ) {
		send_error( "Request token has expired.  Generate new request token (/get_request_token).", 401 );
	}
	my $request_params = {};
	$request_params->{$_} = param($_) foreach qw(
	  oauth_consumer_key
	  oauth_nonce
	  oauth_signature
	  oauth_signature_method
	  oauth_timestamp
	  oauth_token
	  oauth_verifier
	  oauth_version
	);
	my $request = eval {
		Net::OAuth->request('access token')->from_hash(
			$request_params,
			request_method  => request->method,
			request_url     => uri_for("/db/$db/oauth/get_access_token")->as_string,
			consumer_secret => $consumer_secret,
			token_secret    => $request_token->{'secret'},
		);
	};

	if ($@) {
		warn $@;
		if ( $@ =~ /Missing required parameter \'(\w+?)\'/ ) {
			send_error( "Invalid token request. Missing required parameter: $1.", 400 );
		} else {
			$self->{'logger'}->error($@);
			send_error( "Invalid token request.", 400 );
		}
	}
	$self->{'logger'}->debug( "Request string: " . $request->signature_base_string );
	if ( !$request->verify ) {
		send_error( "Signature verification failed.", 401 );
	}
	my $access_token        = BIGSdb::Utils::random_string(32);
	my $access_token_secret = BIGSdb::Utils::random_string(32);
	eval {
		$self->{'auth_db'}->do( "UPDATE request_tokens SET redeemed=? WHERE token=?", undef, 1, $request_token->{'token'} );

		#Replace existing access token for same user.
		$self->{'auth_db'}->do(
			"DELETE FROM access_tokens WHERE (client_id,username,dbase)=(?,?,?)",
			undef,
			param('oauth_consumer_key'),
			$request_token->{'username'},
			$request_token->{'dbase'}
		);
		$self->{'auth_db'}->do(
			"INSERT INTO access_tokens (token,secret,client_id,datestamp,username,dbase) VALUES (?,?,?,?,?,?)",
			undef, $access_token, $access_token_secret, param('oauth_consumer_key'),
			'now',
			$request_token->{'username'},
			$request_token->{'dbase'}
		);
	};
	if ($@) {
		$self->{'logger'}->error($@);
		$self->{'auth_db'}->rollback;
	} else {
		$self->{'auth_db'}->commit;
	}
	return { oauth_token => $access_token, oauth_token_secret => $access_token_secret };
};

#get_session_token
any [qw(get post)] => '/db/:db/oauth/get_session_token' => sub {
	my $self   = setting('self');
	my $params = params;
	my $db     = param('db');
	my $consumer_secret =
	  $self->{'datastore'}
	  ->run_query( "SELECT client_secret FROM clients WHERE client_id=?", param('oauth_consumer_key'), { db => $self->{'auth_db'} } );
	if ( !$consumer_secret ) {
		send_error( "Unrecognized client", 403 );
	}
	my $access_token =
	  $self->{'datastore'}->run_query( "SELECT * FROM access_tokens WHERE token=?",
		param('oauth_token'), { fetch => 'row_hashref', db => $self->{'auth_db'} } );
	if ( !$access_token->{'secret'} ) {
		send_error( "Invalid access token.  Generate new request token (/get_access_token).", 401 );
	}
	my $request_params = {};
	$request_params->{$_} = param($_) foreach qw(
	  oauth_consumer_key
	  oauth_nonce
	  oauth_signature
	  oauth_signature_method
	  oauth_timestamp
	  oauth_token
	  oauth_version
	);
	my $request = eval {
		Net::OAuth->request('protected resource')->from_hash(
			$request_params,
			request_method  => request->method,
			request_url     => uri_for("/db/$db/oauth/get_session_token")->as_string,
			consumer_secret => $consumer_secret,
			token_secret    => $access_token->{'secret'},
		);
	};

	if ($@) {
		warn $@;
		if ( $@ =~ /Missing required parameter \'(\w+?)\'/ ) {
			send_error( "Invalid token request. Missing required parameter: $1.", 400 );
		} else {
			$self->{'logger'}->error($@);
			send_error( "Invalid token request.", 400 );
		}
	}
	$self->{'logger'}->debug( "Request string: " . $request->signature_base_string );
	if ( !$request->verify ) {
		send_error( "Signature verification failed.", 401 );
	}
	my $request_repeated = $self->{'datastore'}->run_query(
		"SELECT EXISTS(SELECT * FROM api_sessions WHERE (nonce,timestamp)=(?,?))",
		[ param('oauth_nonce'), param('oauth_timestamp') ],
		{ db => $self->{'auth_db'} }
	);
	if ($request_repeated) {
		send_error( "Request with same nonce and timestamp already made", 401 );
	}
	my $session_token        = BIGSdb::Utils::random_string(32);
	my $session_token_secret = BIGSdb::Utils::random_string(32);
	eval {
		$self->{'auth_db'}->do(
			"INSERT INTO api_sessions (dbase,username,session,secret,nonce,timestamp,start_time) VALUES (?,?,?,?,?,?,?)",
			undef,
			$access_token->{'dbase'},
			$access_token->{'username'},
			$session_token, $session_token_secret, param('oauth_nonce'), param('oauth_timestamp'), time
		);
	};
	if ($@) {
		$self->{'logger'}->error($@);
		$self->{'auth_db'}->rollback;
	} else {
		$self->{'auth_db'}->commit;
	}
	return { oauth_token => $session_token, oauth_token_secret => $session_token_secret };
};
1;
