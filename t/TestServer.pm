use strict;
use warnings;

# Provide a simple server that can be used to test the various bits.
package TestServer;
use base qw/Test::HTTP::Server::Simple HTTP::Server::Simple::CGI/;

use Time::HiRes qw(sleep time);
use Data::Dumper;
use LWP::UserAgent;

sub handle_request {
    my ( $self, $cgi ) = @_;
    my $params = $cgi->Vars;

    # If we are on port 8081 then we are a proxy - we should forward the
    # requests.
    return act_as_proxy(@_) if $self->port == 8081;

    # Flush the output so that it goes straight away. Needed for the timeout
    # trickle tests.
    $self->stdout_handle->autoflush(1);

    # warn "START REQUEST - " . time;

    # Do the right thing depending on what is asked of us.
    if ( exists $params->{redirect} ) {
        my $num = $params->{redirect} || 0;
        $num--;

        if ( $num > 0 ) {
            print $cgi->redirect( -uri => "?redirect=$num", -nph => 1, );
            print "You are being redirected...";
        }
        else {
            print $cgi->header( -nph => 1 );
            print "No longer redirecting";
        }
    }

    elsif ( exists $params->{delay} ) {
        sleep( $params->{delay} );
        print $cgi->header( -nph => 1 );
        print "Delayed for '$params->{delay}'.\n";

    }

    elsif ( exists $params->{trickle} ) {

        my $trickle_for = $params->{trickle};
        my $finish_at   = time + $trickle_for;

        print $cgi->header( -nph => 1 );

        while ( time <= $finish_at ) {
            print time . " trickle $$\n";
            sleep 0.1;
        }

        print "Trickled for '$trickle_for'.\n";
    }

    elsif ( exists $params->{bad_header} ) {
        my $headers = $cgi->header( -nph => 1, );

        # trim trailing whitspace to single newline.
        $headers =~ s{ \s* \z }{\n}xms;

        # Add a bad header:
        $headers .= "Bad header: BANG!\n";

        print $headers . "\n\n";
        print "Produced some bad headers.";
    }

    elsif ( my $when = $params->{break_connection} ) {

        while (1) {
            last if $when eq 'before_headers';
            print $cgi->header( -nph => 1 );

            last if $when eq 'before_content';
            print "content\n";

            last;
        }
    }

    elsif ( my $id = $params->{set_time} ) {
        my $now = time;
        print $cgi->header( -nph => 1 );
        print "$id\n$now\n";
    }

    else {
        warn "DON'T KNOW WHAT TO DO: " . Dumper $params;
    }

    # warn "STOP REQUEST  - " . time;

}

sub act_as_proxy {
    my ( $self, $cgi ) = @_;

    my $url      = $ENV{REQUEST_URI};
    my $response = LWP::UserAgent->new( max_redirect => 0 )->get($url);

    # Add a header so that we know that this was proxied.
    $response->header( WasProxied => 'yes' );

    print $response->as_string;
}

1;
